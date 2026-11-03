#!/usr/bin/env python3
"""Drive the shipped panel through both shells. Prints one line per observation."""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
MAIN = HERE / "main.py"
FAKE = HERE / "fake_socket.py"
STUBS = {
    "Quickshell",
    "Quickshell.Io",
    "Quickshell.Wayland",
    "Quickshell.Hyprland",
    "Quickshell.Services.Pipewire",
}
FORBIDDEN = (
    "failed:",
    "TypeError",
    "ReferenceError",
    "is not a function",
    "binding loop",
    "QML Row",
)
NOISE = (
    "propertyCache.append",
    "Unable to assign [undefined] to int",
    "QProcess destroyed",
)
BASE_SETTINGS = {
    "activeProfile": "Default",
    "autoConnect": "Off",
    "notifyConnect": "On",
    "notifyDrop": "On",
    "showIpInBar": "Off",
    "showUsername": "Off",
}
STATES = "push:auth,push:connecting,push:connected,push:connected,settings:showIpInBar=On|autoConnect=Off|notifyConnect=On|notifyDrop=On|showUsername=Off|activeProfile=Default,disconnect,push:connected,push:failed,push:failed,open,close,settings:notifyConnect=Off|showIpInBar=On|autoConnect=Off|notifyDrop=On|showUsername=Off|activeProfile=Default"


def require_pyside() -> None:
    parts = tuple(int(piece) for piece in __import__("PySide6").__version__.split(".")[:2])
    if not ((6, 10) <= parts < (6, 12)):
        raise SystemExit(f"PySide6 {parts} is outside >=6.10,<6.12")


def shell_imports(shell: Path) -> set[str]:
    found = set()
    pattern = re.compile(r"(?m)^import\s+(Quickshell(?:\.[\w.]+)?)\b")
    for folder in ("Commons", "Ui"):
        for qml in (shell / folder).rglob("*.qml"):
            found.update(pattern.findall(qml.read_text(encoding="utf-8", errors="replace")))
    return found


def cleaned(text: str) -> str:
    kept = []
    for line in text.splitlines():
        if any(noise in line for noise in NOISE):
            continue
        kept.append(line)
    return "\n".join(kept)


def assert_clean(text: str, where: str) -> None:
    body = cleaned(text)
    for token in FORBIDDEN:
        if token in body:
            raise SystemExit(f"dirty {where}: found {token}\n{body}")
    if "HARNESS_FAIL" in body:
        raise SystemExit(f"dirty {where}: HARNESS_FAIL\n{body}")


def xdg_env(socket_path: str) -> dict[str, str]:
    env = os.environ.copy()
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    for key, name in (
        ("XDG_CONFIG_HOME", "config"),
        ("XDG_CACHE_HOME", "cache"),
        ("XDG_DATA_HOME", "data"),
        ("XDG_STATE_HOME", "state"),
        ("XDG_RUNTIME_DIR", "run"),
    ):
        path = os.path.join(root, name)
        os.makedirs(path, exist_ok=True)
        env[key] = path
    env["QT_QPA_PLATFORM"] = "offscreen"
    env["GPVPN_SOCKET"] = socket_path
    return env


def run_main(shell: Path, settings: dict, steps: str, socket_path: str, plugin: Path | None, trace: bool) -> subprocess.CompletedProcess[str]:
    command = [
        sys.executable, str(MAIN),
        "--omarchy", str(shell),
        "--settings", json.dumps(settings),
        "--do", steps,
        "--settle", "800",
        "--step-delay", "300",
    ]
    if trace:
        command.append("--trace")
    if plugin is not None:
        command.extend(["--plugin", str(plugin)])
    return subprocess.run(command, env=xdg_env(socket_path), text=True, capture_output=True, check=False)


def snaps(proc: subprocess.CompletedProcess[str]) -> list[dict]:
    rows = []
    for line in proc.stdout.splitlines():
        if line.startswith("SNAP "):
            rows.append(json.loads(line[5:]))
    return rows


def start_fake(path: str) -> subprocess.Popen[bytes]:
    if os.path.exists(path):
        os.unlink(path)
    proc = subprocess.Popen([sys.executable, str(FAKE), path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        if os.path.exists(path):
            return proc
        time.sleep(0.05)
    proc.kill()
    raise SystemExit("fake socket did not bind")


def stop_fake(proc: subprocess.Popen[bytes] | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        proc.kill()


def connect_spawns(snap: dict) -> int:
    count = 0
    for command in snap["executed"]:
        if len(command) >= 2 and command[1] == "connect":
            count += 1
    return count


def bodies(snap: dict) -> str:
    return "\n".join(row["stdin"] for row in snap["piped"])


def scenario_setup(shell: Path) -> None:
    missing = str(Path(tempfile.mkdtemp(prefix="omaglobal-sock-")) / "missing.sock")
    proc = run_main(shell, BASE_SETTINGS, "", missing, None, True)
    assert_clean(proc.stdout + proc.stderr, "setup")
    if proc.returncode != 0:
        raise SystemExit(f"setup load failed\n{proc.stderr}")
    row = snaps(proc)[-1]
    if not (row["setupVisible"] is True and row["setupCommand"] == "tools/setup.sh" and row["phase"] == "off" and row["socketUp"] is False):
        raise SystemExit(f"setup card mismatch {row}")
    print(f"SETUP setupVisible=true command={row['setupCommand']}")


def scenario_states(shell: Path) -> None:
    sock_dir = tempfile.mkdtemp(prefix="omaglobal-sock-")
    sock = os.path.join(sock_dir, "ctrl.sock")
    fake = start_fake(sock)
    try:
        proc = run_main(shell, BASE_SETTINGS, STATES, sock, None, True)
        assert_clean(proc.stdout + proc.stderr, "states")
        if proc.returncode != 0:
            raise SystemExit(f"states load failed\n{proc.stderr}\n{proc.stdout}")
        rows = snaps(proc)
        if len(rows) != 13:
            raise SystemExit(f"expected 13 snapshots, got {len(rows)}")
        expect = [
            ("off", "dim", True),
            ("auth", "amber", False),
            ("connecting", "amber", False),
            ("connected", "green", False),
            ("connected", "green", False),
        ]
        for index, (phase, role, dimmed) in enumerate(expect):
            row = rows[index]
            if row["phase"] != phase or row["iconRole"] != role or row["dimmed"] is not dimmed:
                raise SystemExit(f"state {index} {row['phase']} {row['iconRole']} dimmed={row['dimmed']}")
        shown = rows[5]
        if shown["showIpInBar"] is not True or shown["barIp"] != "172.16.8.8" or shown["phase"] != "connected":
            raise SystemExit(f"show IP did not apply {shown['showIpInBar']} {shown['barIp']} {shown['phase']}")
        if shown["ip"] != "172.16.8.8" or shown["gateway"] != "PROD-EXAMPLE" or shown["expires"] != "2030-01-01T00:00:00":
            raise SystemExit(f"session facts missing {shown['ip']} {shown['gateway']} {shown['expires']}")
        if rows[6]["phase"] != "off" or rows[6]["notifyDisconnectCount"] != 1:
            raise SystemExit(f"disconnect did not idle {rows[6]['phase']} {rows[6]['notifyDisconnectCount']}")
        if rows[8]["phase"] != "failed" or rows[8]["iconRole"] != "urgent" or rows[8]["notifyDropCount"] != 1:
            raise SystemExit(f"drop state mismatch {rows[8]}")
        if rows[9]["notifyDropCount"] != 1 or rows[4]["notifyConnectCount"] != 1 or rows[7]["notifyConnectCount"] != 2:
            raise SystemExit("notification counts moved more than once per event")
        if rows[10]["opened"] is not True or rows[11]["opened"] is not False:
            raise SystemExit(f"close path {rows[10]['opened']} {rows[11]['opened']}")
        if rows[12]["notifyConnect"] is not False or rows[0]["autoConnect"] is not False or rows[0]["notifyConnect"] is not True:
            raise SystemExit("settings did not apply at construction and on change")
        blob = bodies(rows[-1])
        if "user@example.com" in blob or "AAAA" in blob or "cookie" in blob.lower():
            raise SystemExit(f"notification leaked {blob}")
        if connect_spawns(rows[-1]) != 0:
            raise SystemExit("auto-connect off still spawned connect")
        if "failed:" in rows[8]["statusLine"]:
            raise SystemExit(rows[8]["statusLine"])
        print("STATES off auth connecting connected failed")
        print("ROLES dim amber amber green urgent")
        print("CLOSE opened=true then false")
        print(f"SETTINGS showIpInBar=true barIp={shown['barIp']} notifyConnect=false")
        print("NOTIFY connect=1 disconnect=1 drop=1 cookie=absent username=absent")
    finally:
        stop_fake(fake)


def scenario_auto(shell: Path, enabled: bool) -> None:
    sock_dir = tempfile.mkdtemp(prefix="omaglobal-sock-")
    sock = os.path.join(sock_dir, "ctrl.sock")
    fake = start_fake(sock)
    try:
        settings = dict(BASE_SETTINGS)
        settings["autoConnect"] = "On" if enabled else "Off"
        proc = run_main(shell, settings, "", sock, None, True)
        assert_clean(proc.stdout + proc.stderr, "autoconnect")
        if proc.returncode != 0:
            raise SystemExit(proc.stderr)
        row = snaps(proc)[-1]
        count = connect_spawns(row)
        expect = 1 if enabled else 0
        if count != expect or (enabled and row["autoTried"] is not True):
            raise SystemExit(f"autoconnect spawns={count} autoTried={row['autoTried']}")
        label = "AUTOCONNECT" if enabled else "AUTOCONNECT_OFF"
        print(f"{label} spawns={count}")
    finally:
        stop_fake(fake)


def scenario_negative(shell: Path) -> None:
    copy = Path(tempfile.mkdtemp(prefix="omaglobal-dimmed-"))
    for name in ("Panel.qml", "OmaStore.qml", "OmaPopup.qml", "qmldir"):
        shutil.copy(REPO / name, copy / name)
    panel = (copy / "Panel.qml").read_text(encoding="utf-8")
    needle = "Panel {\n"
    if needle not in panel:
        raise SystemExit("panel root marker missing")
    (copy / "Panel.qml").write_text(panel.replace(needle, "Panel {\n  dimmed: true\n", 1), encoding="utf-8")
    missing = str(copy / "missing.sock")
    proc = run_main(shell, BASE_SETTINGS, "", missing, copy / "Panel.qml", False)
    combined = proc.stdout + "\n" + proc.stderr
    if proc.returncode == 0 or "HARNESS_FAIL" not in combined or "dimmed" not in combined:
        raise SystemExit(f"dimmed-on-root did not fail\n{combined}")
    print("NEGATIVE HARNESS_FAIL")


def main() -> int:
    require_pyside()
    shell = Path(sys.argv[1]).resolve()
    label = sys.argv[2] if len(sys.argv) > 2 else shell.name
    print(f"SHELL {label}")
    missing = sorted(shell_imports(shell) - STUBS)
    if missing:
        raise SystemExit("unstubbed " + " ".join(missing))
    print("STUBS complete")
    scenario_setup(shell)
    scenario_states(shell)
    scenario_auto(shell, True)
    scenario_auto(shell, False)
    scenario_negative(shell)
    print("CLEAN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
