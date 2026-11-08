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


def xdg_env(socket_path: str, root: str | None = None) -> dict[str, str]:
    env = os.environ.copy()
    if root is None:
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
    env.setdefault("GPVPN_DAEMON", str(REPO / "bin" / "gpvpnd"))
    return env


def run_main(shell: Path, settings: dict, steps: str, socket_path: str, plugin: Path | None, trace: bool, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
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
    if env is None:
        env = xdg_env(socket_path)
    else:
        env = dict(env)
        env["GPVPN_SOCKET"] = socket_path
        env["QT_QPA_PLATFORM"] = "offscreen"
    return subprocess.run(command, env=env, text=True, capture_output=True, check=False)


def require_confirm_above_bar(rows: list[dict], where: str) -> None:
    for index, row in enumerate(rows):
        if row.get("confirmAboveBar") is False:
            raise SystemExit(f"remove-confirm clipped under the pinned bar in {where} snapshot {index}")


def require_no_overlaps(rows: list[dict], where: str) -> None:
    """The r3 review requires failing when sibling text rectangles intersect."""
    for index, row in enumerate(rows):
        bad = row.get("overlaps") or []
        if bad:
            raise SystemExit(f"overlapping text in {where} snapshot {index}: {'; '.join(bad)}")


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
    require_no_overlaps([row], "scenario")
    command = str(row["setupCommand"])
    if not (row["setupVisible"] is True and command.endswith("tools/setup.sh") and row["phase"] == "off" and row["socketUp"] is False):
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
        require_no_overlaps(rows, "scenario")
        require_confirm_above_bar(rows, "scenario")
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
        if rows[8]["detail"] == "":
            raise SystemExit(f"failure detail did not reach the store {rows[8]['detail']!r}")
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


def scenario_connect(shell: Path, plugin: Path | None = None) -> None:
    """Connect with no profile asks for a portal in the form, then the typed values are saved by the helper."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "ctrl.sock")
    env = xdg_env(sock, root)
    plugin_qml = plugin if plugin is not None else (REPO / "Panel.qml")
    helper = plugin_qml.parent / "bin" / "gpvpn"
    fake = start_fake(sock)
    try:
        steps = "open,connect,type:portalField=vpn.example.com,type:usernameField=user@example.com,connect,wait:900"
        proc = run_main(shell, BASE_SETTINGS, steps, sock, plugin_qml, True, env)
        assert_clean(proc.stdout + proc.stderr, "connect")
        if proc.returncode != 0:
            raise SystemExit(f"connect load failed\n{proc.stderr}\n{proc.stdout}")
        rows = snaps(proc)
        require_no_overlaps(rows, "scenario")
        require_confirm_above_bar(rows, "scenario")
        require_no_overlaps(rows, "scenario")
        require_confirm_above_bar(rows, "scenario")
        if len(rows) < 4:
            raise SystemExit(f"connect snapshots missing {len(rows)}")
        opened = rows[1]
        empty = rows[2]
        shown = rows[-1]
        if opened["opened"] is not True or opened["socketUp"] is not True or opened["phase"] != "off":
            raise SystemExit(f"connect did not start from a disconnected dropdown {opened}")
        empty_text = f"{empty['statusLine']}\n{empty['errorLine']}"
        if empty["phase"] != "failed" or "portal" not in empty["statusLine"].lower():
            raise SystemExit(f"empty connect did not ask for a portal {empty['phase']} {empty['statusLine']!r}")
        if "gpvpn" in empty_text or "setup.sh" in empty_text or connect_spawns(empty) != 0:
            raise SystemExit(f"empty connect ran a command {empty_text!r} spawns={connect_spawns(empty)}")
        adds = [command for command in shown["executed"] if len(command) >= 3 and command[1:3] == ["profile", "save"]]
        if len(adds) != 1 or Path(adds[0][0]).resolve() != helper.resolve():
            raise SystemExit(f"profile was not saved by the helper {adds}")
        if "vpn.example.com" not in adds[0][-1] or "user@example.com" not in adds[0][-1]:
            raise SystemExit(f"saved command missed the typed values {adds[0]}")
        if connect_spawns(shown) != 1:
            raise SystemExit(f"connect after save spawned {connect_spawns(shown)}")
        saved = json.loads((Path(env["XDG_CONFIG_HOME"]) / "gp-vpn" / "profiles.json").read_text(encoding="utf-8"))
        stored = saved.get("profiles") or []
        if len(stored) != 1 or stored[0].get("portal") != "vpn.example.com" or stored[0].get("username") != "user@example.com":
            raise SystemExit(f"profile file mismatch {stored}")
        if re.search(r"[A-Za-z0-9+/=]{40,}", empty_text):
            raise SystemExit(f"cookie-like secret shown {empty_text}")
        print("CONNECT form saved=vpn.example.com")
    finally:
        stop_fake(fake)


def scenario_auto(shell: Path, enabled: bool, stale: bool = False) -> None:
    """stale: the root daemon predates the plugin, so auto-connect waits for Update."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "ctrl.sock")
    env = ready_env(root, sock)
    if stale:
        old = Path(root) / "gpvpnd-0.2.10"
        old.write_text("older build\n")
        env["GPVPN_DAEMON"] = str(old)
    if enabled:
        seeded = subprocess.run(
            [str(REPO / "bin" / "gpvpn"), "profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"],
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if seeded.returncode != 0:
            raise SystemExit(seeded.stderr)
    fake = start_fake(sock)
    try:
        settings = dict(BASE_SETTINGS)
        settings["autoConnect"] = "On" if enabled else "Off"
        proc = run_main(shell, settings, "", sock, None, True, env)
        assert_clean(proc.stdout + proc.stderr, "autoconnect")
        if proc.returncode != 0:
            raise SystemExit(proc.stderr)
        row = snaps(proc)[-1]
        require_no_overlaps([row], "scenario")
        count = connect_spawns(row)
        expect = 1 if enabled and not stale else 0
        if count != expect or (expect and row["autoTried"] is not True):
            raise SystemExit(f"autoconnect spawns={count} autoTried={row['autoTried']}")
        label = "AUTOCONNECT_STALE" if stale else "AUTOCONNECT" if enabled else "AUTOCONNECT_OFF"
        print(f"{label} spawns={count}")
    finally:
        stop_fake(fake)


def scenario_profile(shell: Path) -> None:
    """A saved active profile loads over the widget default, and a dropdown choice is written back."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    env = xdg_env(os.path.join(root, "missing.sock"), root)
    helper = [sys.executable, str(REPO / "bin" / "gpvpn")]
    for args in (
        ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"],
        ["profile", "add", "--name", "Other", "--portal", "vpn.example.com", "--username", "user@example.com"],
        ["profile", "set", "Other", "active", "yes"],
    ):
        seeded = subprocess.run(helper + args, env=env, text=True, capture_output=True, check=False)
        if seeded.returncode != 0:
            raise SystemExit(seeded.stderr)
    proc = run_main(shell, BASE_SETTINGS, "choose:Default", env["GPVPN_SOCKET"], None, True, env)
    assert_clean(proc.stdout + proc.stderr, "profile")
    if proc.returncode != 0:
        raise SystemExit(f"profile load failed\n{proc.stderr}\n{proc.stdout}")
    rows = snaps(proc)
    require_no_overlaps(rows, "scenario")
    if len(rows) < 2 or rows[0]["activeProfile"] != "Other":
        raise SystemExit(f"saved profile did not load {rows[0]['activeProfile'] if rows else 'none'}")
    if rows[-1]["activeProfile"] != "Default":
        raise SystemExit(f"dropdown choice did not stick {rows[-1]['activeProfile']}")
    saved = json.loads((Path(env["XDG_CONFIG_HOME"]) / "gp-vpn" / "profiles.json").read_text(encoding="utf-8"))
    if saved.get("active") != "Default":
        raise SystemExit(f"profile set did not persist {saved.get('active')}")
    print("PROFILE loaded=Other saved=Default")


FAKE_SAML = """import os, sys, time
if os.environ.get("FAKE_SAML_HOLD"):
    open(os.environ["FAKE_SAML_HOLD"], "w").write(str(os.getpid()))
    time.sleep(60)
sys.stderr.write(\"\"\"Looking for SAML auth tags in response to https://vpn.example.com/ssl-vpn/prelogin.esp...
Got SAML POST, opening browser...

SAML response converted to OpenConnect command line invocation:

    echo AAAAfakeCookieValue0123456789abcdef===== |
        sudo openconnect --protocol=gp '--useragent=PAN GlobalProtect' --user=user@example.com --os=linux-64 --usergroup=portal:prelogin-cookie --passwd-on-stdin vpn.example.com

SAML response converted to test-globalprotect-login.py invocation:

    test-globalprotect-login.py --user=user@example.com --clientos=Linux -p '' \\\\
         https://vpn.example.com/global-protect/getconfig.esp prelogin-cookie=AAAAfakeCookieValue0123456789abcdef=====

\"\"\")
"""


def ready_env(root: str, sock: str) -> dict[str, str]:
    """A machine where setup already ran: the helper reports ready, the sign-in
    tool is a stand-in that prints gp-saml-gui's real output."""
    env = xdg_env(sock, root)
    bin_dir = Path(root) / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake_git = bin_dir / "git"
    fake_git.write_text('#!/usr/bin/env bash\necho 21cce40334791a533c7a263fe367f0ddc072d8fb\n')
    fake_git.chmod(0o755)
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["GPVPN_DAEMON"] = str(REPO / "bin" / "gpvpnd")
    saml = Path(env["XDG_DATA_HOME"]) / "gp-vpn" / "gp-saml-gui" / "gp_saml_gui.py"
    saml.parent.mkdir(parents=True, exist_ok=True)
    saml.write_text(FAKE_SAML)
    return env


def real_daemon(root: str, sock: str, env: dict[str, str]) -> subprocess.Popen[bytes]:
    """The real gpvpnd as this user, with openconnect replaced by the fixture."""
    run_env = {**env, "FAKE_OC_DIR": os.path.join(root, "oc")}
    proc = subprocess.Popen(
        [sys.executable, str(REPO / "bin" / "gpvpnd"), "--socket", sock,
         "--openconnect", str(REPO / "tests" / "fixtures" / "fake-openconnect"),
         "--state-file", os.path.join(root, "daemon.json")],
        env=run_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    for _ in range(100):
        if os.path.exists(sock):
            return proc
        time.sleep(0.05)
    proc.terminate()
    raise SystemExit("daemon did not start")


def seed(env: dict[str, str], *rows: list[str]) -> None:
    helper = [sys.executable, str(REPO / "bin" / "gpvpn")]
    for args in rows:
        done = subprocess.run(helper + args, env=env, text=True, capture_output=True, check=False)
        if done.returncode != 0:
            raise SystemExit(done.stderr)


def steps_ok(proc: subprocess.CompletedProcess[str], where: str) -> None:
    if proc.returncode != 0 or "STEP FAILED" in proc.stdout + proc.stderr:
        raise SystemExit(f"{where}\n{proc.stdout[-1500:]}\n{proc.stderr[-1500:]}")


def saved_store(env: dict[str, str]) -> dict:
    return json.loads((Path(env["XDG_CONFIG_HOME"]) / "gp-vpn" / "profiles.json").read_text(encoding="utf-8"))


ADD = ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"]
ADD2 = ["profile", "add", "--name", "Home", "--portal", "vpn.example.net"]


def scenario_editor_controls(shell: Path) -> None:
    """Every editor control, with real mouse clicks. Each one must visibly change
    the moment it is clicked, and Save must store what the screen showed."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    seed(env, ADD, ADD2)
    fake = start_fake(sock)
    try:
        steps = ",".join([
            "open", "screen:main", "mouse:profileEditButton#1", "screen:editor",
            # Nothing is touched yet: portal sign-in is the normal path.
            "expect:editorAuth/SSO:active=true", "expect:editorInterface/Portal:active=true",
            "expect:editorInterface/Gateway:active=false",
            "mouse:editorAuth/Password", "expect:editorAuth/Password:active=true",
            "expect:editorAuth/SSO:active=false",
            "mouse:editorAuth/SSO", "expect:editorAuth/SSO:active=true",
            "mouse:editorAuth/Password", "expect:editorAuth/Password:active=true",
            "mouse:editorInterface/Gateway", "expect:editorInterface/Gateway:active=true",
            "expect:editorInterface/Portal:active=false",
            "mouse:editorInterface/Portal", "expect:editorInterface/Portal:active=true",
            "mouse:editorInterface/Gateway", "expect:editorInterface/Gateway:active=true",
            "mouse:editorAdvancedToggle",
            "expect:editorOs/Auto:active=true", "mouse:editorOs/Windows",
            "expect:editorOs/Windows:active=true", "expect:editorOs/Auto:active=false",
            "expect:editorNoDtls:checked=false", "mouse:editorNoDtls", "expect:editorNoDtls:checked=true",
            "mouse:editorNoDtls", "expect:editorNoDtls:checked=false", "mouse:editorNoDtls",
            # A problem keeps the editor open and says why.
            "mouse:editorSave", "await:editorError:text=Password sign-in needs a username.",
            "expect:editorError:visible=true",
            "fill:editorUsername=user@example.com", "fill:editorBaseMtu=abc", "mouse:editorSave",
            "await:editorError:text=Tunnel packet size must be a number from 576 to 65535.",
            "fill:editorBaseMtu=1300", "fill:editorPortal=", "mouse:editorSave",
            "await:editorError:text=Enter the VPN portal address.",
            "fill:editorPortal=https://vpn.example.org/global-protect/", "fill:editorName=Renamed",
            "mouse:editorSave", "screen:main",
            # The saved values come back, on the VPN that was edited.
            "wait:300", "mouse:profileEditButton#1", "screen:editor",
            "expect:editorAuth/Password:active=true", "expect:editorInterface/Gateway:active=true",
            "expect:editorName:text=Renamed", "mouse:editorAdvancedToggle",
            "expect:editorOs/Windows:active=true", "expect:editorNoDtls:checked=true",
            "expect:editorBaseMtu:text=1300",
            # Blanks clear a setting.
            "fill:editorBaseMtu=", "mouse:editorSave", "screen:main",
        ])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "editor controls")
    finally:
        stop_fake(fake)
    store = saved_store(env)
    edited = next((row for row in store["profiles"] if row["name"] == "Renamed"), None)
    if edited is None or len(store["profiles"]) != 2:
        raise SystemExit(f"editor saved the wrong VPN {store}")
    wanted = {"portal": "vpn.example.org", "authMethod": "password", "interface": "gateway",
              "os": "win", "noDtls": True, "username": "user@example.com"}
    for key, value in wanted.items():
        if edited.get(key) != value:
            raise SystemExit(f"editor saved {key}={edited.get(key)!r}")
    if "baseMtu" in edited:
        raise SystemExit("a blank MTU did not clear the setting")
    if store["active"] != "Work":
        raise SystemExit(f"saving moved the default to {store['active']}")
    print("CONTROLS every editor control answers a real click")


def scenario_manage(shell: Path) -> None:
    """Set as default, Forget, Remove, Keep it, Add a VPN, Back, gateway pick."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    seed(env, ADD, ADD2, ["profile", "set", "Home", "gateways",
                          json.dumps([{"name": "EAST", "host": "east.example.net", "priority": 1},
                                      {"name": "WEST", "host": "west.example.net", "priority": 2}])])
    fake = start_fake(sock)
    try:
        steps = ",".join([
            "open", "screen:main", "mouse:profileEditButton#1", "screen:editor",
            "expect:gatewayAuto:active=true", "mouse:gatewayButton#1",
            "expect:gatewayButton#1:active=true", "expect:gatewayAuto:active=false",
            "mouse:gatewayAuto", "expect:gatewayAuto:active=true",
            "mouse:gatewayButton#1", "mouse:editorSave", "screen:main",
            "wait:300", "mouse:profileEditButton#1", "screen:editor",
            "expect:gatewayButton#1:active=true",
            "expect:editorDefault:text=Set as default", "mouse:editorDefault",
            "await:editorDefault:text=This is your default VPN",
            "expect:editorForget:text=Forget saved sign-in", "mouse:editorForget",
            "await:editorForget:text=Saved sign-in forgotten",
            "mouse:editorRemove", "expect:removeConfirm:visible=true",
            "mouse:removeNo", "expect:removeConfirm:visible=false",
            "mouse:editorBack", "screen:main",
            "mouse:addVpn", "screen:editor", "expect:editorDefault:visible=false",
            "expect:editorInterface/Portal:active=true",
            "fill:editorPortal=vpn.example.edu", "mouse:editorSave", "screen:main",
            "wait:300", "mouse:profileEditButton#2", "screen:editor",
            "mouse:editorRemove", "mouse:removeYes", "screen:main",
        ])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "manage")
    finally:
        stop_fake(fake)
    store = saved_store(env)
    names = [row["name"] for row in store["profiles"]]
    if names != ["Work", "Home"] or store["active"] != "Work":
        raise SystemExit(f"manage left {names} active={store['active']}")
    home = store["profiles"][1]
    if home["gatewayName"] != "WEST" or home["gateway"] != "west.example.net":
        raise SystemExit(f"gateway pick not saved {home}")
    print("MANAGE default, forget, remove, add and gateway answer a real click")


def scenario_real_connect(shell: Path) -> None:
    """Welcome to Connected through the real helper and the real daemon. Only
    openconnect and the sign-in window are stand-ins, printing their real text."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    daemon = real_daemon(root, sock, env)
    try:
        steps = ",".join([
            "open", "screen:welcome", "fill:portalField=vpn.example.com", "mouse:connectButton",
            "screen:main", "await:heroState:text=Connected",
            "expect:vpnIp:text=Address  172.16.8.8", "expect:vpnGateway:text=Gateway  PROD-EXAMPLE",
            "mouse:reconnectButton", "wait:300", "await:heroState:text=Connected",
            "mouse:vpnConnectButton", "await:heroState:text=Disconnected",
        ])
        proc = run_main(shell, {**BASE_SETTINGS, "autoConnect": False}, steps, sock, None, False, env)
        steps_ok(proc, "real connect")
    finally:
        daemon.terminate()
        daemon.wait(timeout=5)
    argv = Path(root, "oc", "argv").read_text(encoding="utf-8").split("\n")
    if "vpn.example.com" not in argv or "--usergroup" not in argv:
        raise SystemExit(f"openconnect got {argv}")
    print("REALCONNECT welcome to connected to disconnected")


def scenario_shield(shell: Path) -> None:
    """Bar and dropdown share one mood, and a retry inside a connect never flashes failure."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    seed(env, ADD)
    fake = start_fake(sock)
    try:
        moods = [("off", "off"), ("auth", "busy"), ("connecting", "busy"), ("connected", "on"), ("failed", "fail"), ("off", "off")]
        steps = ["open", "screen:main"]
        for pushed, mood in moods:
            steps += [f"push:{pushed}", f"await:heroShield:mood={mood}", f"expect:barGlyph:mood={mood}"]
        proc = run_main(shell, BASE_SETTINGS, ",".join(steps), sock, None, False, env)
        steps_ok(proc, "shield moods")
    finally:
        stop_fake(fake)

    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    env["FAKE_OC_MODE"] = "need-authgroup"
    seed(env, ADD)
    daemon = real_daemon(root, sock, env)
    try:
        # Watching starts first: the retry is over in milliseconds.
        steps = "open,screen:main,connectWatched:heroShield:mood=fail,await:heroState:text=Connected"
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "shield retry")
    finally:
        daemon.terminate()
        daemon.wait(timeout=5)
    print("SHIELD one mood everywhere; a retry stays busy")


def scenario_cancel(shell: Path) -> None:
    """Cancel closes the sign-in window, and a password VPN asks every time."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    hold = os.path.join(root, "saml.pid")
    env["FAKE_SAML_HOLD"] = hold
    seed(env, ADD)
    daemon = real_daemon(root, sock, env)
    try:
        steps = ",".join([
            "open", "screen:main", "mouse:vpnConnectButton", "await:heroState:text=Connecting",
            "wait:900", "mouse:vpnConnectButton", "await:heroState:text=Disconnected", "wait:500",
        ])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "cancel")
        pid = int(Path(hold).read_text(encoding="utf-8"))
        if os.path.exists(f"/proc/{pid}") and "Z" not in Path(f"/proc/{pid}/stat").read_text().split()[2]:
            os.kill(pid, 9)
            raise SystemExit("Cancel left the sign-in window open")

        env.pop("FAKE_SAML_HOLD")
        seed(env, ["profile", "set", "Work", "username", "user@example.com"],
             ["profile", "set", "Work", "authMethod", "password"])
        steps = ",".join([
            "open", "screen:main", "mouse:vpnConnectButton", "expect:passwordCard:visible=true",
            "mouse:passwordCancel", "expect:passwordCard:visible=false",
            "mouse:vpnConnectButton", "expect:passwordCard:visible=true",
            # The button under the field must work, not just Enter.
            "mouse:vpnConnectButton", "expect:passwordCard:visible=true",
            "fill:passwordField=-first try", "mouse:vpnConnectButton",
            "await:heroState:text=Connected",
            "mouse:reconnectButton", "await:passwordCard:visible=true",
            "fill:passwordField=second", "mouse:vpnConnectButton", "await:heroState:text=Connected",
            "mouse:vpnConnectButton", "await:heroState:text=Disconnected",
        ])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "password")
    finally:
        daemon.terminate()
        daemon.wait(timeout=5)
    log = Path(root, "oc", "stdin").read_text(encoding="utf-8")
    if log.strip() != "second":
        raise SystemExit(f"second password was not delivered {log!r}")
    print("CANCEL sign-in window closes; password asks every attempt")


def scenario_fail_details(shell: Path) -> None:
    """A failed connect keeps the tunnel's own lines behind a small (see More)."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "ctrl.sock")
    env = ready_env(root, sock)
    seed(env, ADD)
    fake = start_fake(sock)
    try:
        steps = ",".join([
            "push:failed", "open", "screen:main",
            "expect:failDetailToggle:visible=true",
            "mouse:failDetailToggle", "expect:failDetailToggle:text=Hide details",
            "expect:failDetailCard:visible=true",
            "mouse:failDetailToggle", "expect:failDetailToggle:text=(see More)",
            "expect:failDetailCard:visible=false",
        ])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, True, env)
        steps_ok(proc, "fail details")
        row = snaps(proc)[-1]
        require_no_overlaps([row], "scenario")
        if "Network is unreachable" not in row["failDetailText"]:
            raise SystemExit(f"details toggle did not reveal the raw lines {row['failDetailText']!r}")
    finally:
        stop_fake(fake)
    print("FAILDETAILS (see More) reveals the tunnel's own lines")


def scenario_update(shell: Path) -> None:
    """A plugin update with an older daemon offers Update, not a broken connect."""
    root = tempfile.mkdtemp(prefix="omaglobal-xdg-")
    sock = os.path.join(root, "run", "ctrl.sock")
    env = ready_env(root, sock)
    old = Path(root, "old-gpvpnd")
    old.write_text("older build\n")
    env["GPVPN_DAEMON"] = str(old)
    seed(env, ADD)
    fake = start_fake(sock)
    try:
        steps = ",".join(["open", "screen:setup", "expect:installSetup:text=Update",
                          "mouse:setupDetailsToggle", "expect:setupDetailsToggle:text=Hide details"])
        proc = run_main(shell, BASE_SETTINGS, steps, sock, None, False, env)
        steps_ok(proc, "update")
    finally:
        stop_fake(fake)
    print("UPDATE an older daemon offers Update")


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


def shell_dir(path: Path) -> Path:
    """Accept either a shell tree or an Omarchy checkout that keeps it under shell/."""
    if (path / "Commons").is_dir() and (path / "Ui").is_dir():
        return path
    nested = path / "shell"
    if (nested / "Commons").is_dir() and (nested / "Ui").is_dir():
        return nested
    return path


def main() -> int:
    require_pyside()
    shell = shell_dir(Path(sys.argv[1]).resolve())
    label = sys.argv[2] if len(sys.argv) > 2 else shell.name
    plugin = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else None
    print(f"SHELL {label}")
    missing = sorted(shell_imports(shell) - STUBS)
    if missing:
        raise SystemExit("unstubbed " + " ".join(missing))
    print("STUBS complete")
    scenario_setup(shell)
    scenario_states(shell)
    scenario_connect(shell, plugin)
    scenario_auto(shell, True)
    scenario_auto(shell, False)
    scenario_auto(shell, True, stale=True)
    scenario_profile(shell)
    scenario_editor_controls(shell)
    scenario_manage(shell)
    scenario_real_connect(shell)
    scenario_shield(shell)
    scenario_cancel(shell)
    scenario_fail_details(shell)
    scenario_update(shell)
    scenario_negative(shell)
    print("CLEAN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
