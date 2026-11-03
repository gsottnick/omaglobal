#!/usr/bin/env python3
"""Load the shipped OmaGlobal panel against one Omarchy shell tree."""

import argparse
import json
import os
import socket
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import QTimer, QUrl  # noqa: E402
from PySide6.QtGui import QGuiApplication  # noqa: E402
from PySide6.QtQml import QQmlApplicationEngine  # noqa: E402

from qsmock import core, hyprland, io, pipewire, wayland  # noqa: E402,F401

STUBS = (
    "Quickshell",
    "Quickshell.Io",
    "Quickshell.Wayland",
    "Quickshell.Hyprland",
    "Quickshell.Services.Pipewire",
)

PUSH = {
    "off": {"state": "idle"},
    "auth": {"state": "auth"},
    "connecting": {"state": "connecting"},
    "connected": {
        "state": "connected",
        "ip": "172.16.8.8",
        "gateway": "PROD-EXAMPLE",
        "expires": "2030-01-01T00:00:00",
        "user": "user@example.com",
    },
    "failed": {"state": "dropped", "message": "Tunnel closed"},
}


def build_import_root(omarchy_shell: Path) -> Path:
    root = HERE / ".qsroot"
    (root / "qs").mkdir(parents=True, exist_ok=True)
    for name in ("Commons", "Ui"):
        link = root / "qs" / name
        target = omarchy_shell / name
        if not target.is_dir():
            raise SystemExit(f"missing {target}")
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(target)
    for module in STUBS:
        directory = root.joinpath(*module.split("."))
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "qmldir").write_text(f"module {module}\n")
    return root


def read_prop(obj, name, default=None):
    if obj is None:
        return default
    value = obj.property(name)
    return default if value is None else value


def snapshot(plugin, store):
    button = plugin.findChild(type(plugin), "barButton") if plugin is not None else None
    # findChild with a type filter misses sibling types; search by name.
    button = None
    phase_text = ""
    if plugin is not None:
        from PySide6.QtCore import QObject

        button = plugin.findChild(QObject, "barButton")
        status = plugin.findChild(QObject, "statusLine")
        error = plugin.findChild(QObject, "errorLine")
        connect_button = plugin.findChild(QObject, "connectButton")
        phase_text = read_prop(status, "text", "")
    piped = [{"command": row["command"], "stdin": row["stdin"]} for row in io.PIPED]
    return {
        "phase": read_prop(plugin, "phase", ""),
        "iconRole": read_prop(plugin, "iconRole", ""),
        "dimmed": read_prop(button, "dimmed", None),
        "setupVisible": read_prop(plugin, "setupVisible", None),
        "setupCommand": read_prop(plugin, "setupCommand", ""),
        "opened": read_prop(plugin, "opened", None),
        "pulseRunning": bool(plugin.findChild(type(plugin), "authPulse")) if False else None,
        "statusLine": phase_text,
        "errorLine": read_prop(error, "text", "") if plugin is not None else "",
        "connectText": read_prop(connect_button, "text", "") if plugin is not None else "",
        "barIp": read_prop(plugin.findChild(QObject, "barIp"), "text", "") if plugin is not None else "",
        "ip": read_prop(plugin, "vpnIp", ""),
        "gateway": read_prop(plugin, "vpnGateway", ""),
        "expires": read_prop(plugin, "vpnExpires", ""),
        "socketUp": read_prop(plugin, "socketUp", None),
        "autoConnect": read_prop(plugin, "autoConnect", None),
        "notifyConnect": read_prop(plugin, "notifyConnect", None),
        "notifyDrop": read_prop(plugin, "notifyDrop", None),
        "showIpInBar": read_prop(plugin, "showIpInBar", None),
        "showUsername": read_prop(plugin, "showUsername", None),
        "notifyConnectCount": read_prop(plugin, "notifyConnectCount", 0),
        "notifyDisconnectCount": read_prop(plugin, "notifyDisconnectCount", 0),
        "notifyDropCount": read_prop(plugin, "notifyDropCount", 0),
        "autoTried": read_prop(plugin, "autoTried", None),
        "activeProfile": read_prop(plugin, "activeProfile", ""),
        "piped": piped,
        "executed": [list(command) for command in io.EXECUTED],
    }


def push(name):
    payload = {"cmd": "push", **PUSH[name]}
    path = os.environ.get("GPVPN_SOCKET", "")
    if not path:
        raise SystemExit("GPVPN_SOCKET is not set")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(path)
    client.sendall((json.dumps(payload) + "\n").encode())
    client.close()


def apply_step(step, plugin, store):
    name, _, argument = step.partition(":")
    if name == "open":
        plugin.open()
    elif name == "close":
        plugin.close()
    elif name == "push":
        push(argument)
    elif name == "disconnect":
        plugin.requestDisconnect()
    elif name == "type":
        from PySide6.QtCore import QObject

        target, _, value = argument.partition("=")
        field = plugin.findChild(QObject, target)
        if field is None:
            raise SystemExit(f"field missing: {target}")
        field.setProperty("text", value)
    elif name == "connect":
        from PySide6.QtCore import QObject

        button = plugin.findChild(QObject, "connectButton")
        if button is None:
            raise SystemExit("connect button missing")
        clicked = getattr(button, "clicked", None)
        if clicked is None:
            raise SystemExit("connect button has no clicked signal")
        if hasattr(clicked, "emit"):
            clicked.emit()
        else:
            clicked()
    elif name == "choose":
        plugin.chooseProfile(argument)
    elif name == "settings":
        current = dict(read_prop(plugin, "settings", {}) or {})
        for pair in argument.split("|"):
            key, _, value = pair.partition("=")
            current[key] = value
        plugin.setProperty("settings", current)
    elif name == "wait":
        return
    else:
        raise SystemExit(f"unknown step: {step}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--omarchy", default=os.environ.get("OMARCHY_SHELL", "/usr/share/omarchy/shell"))
    parser.add_argument("--plugin", default=str(REPO / "Panel.qml"))
    parser.add_argument("--settings", default="{}")
    parser.add_argument("--dump", default="")
    parser.add_argument("--do", default="")
    parser.add_argument("--settle", type=int, default=400)
    parser.add_argument("--step-delay", type=int, default=200)
    parser.add_argument("--trace", action="store_true")
    args = parser.parse_args()

    omarchy = Path(args.omarchy).expanduser().resolve()
    import_root = build_import_root(omarchy)
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QGuiApplication(sys.argv[:1])
    engine = QQmlApplicationEngine()
    engine.addImportPath(str(import_root))
    engine.addImportPath(str(HERE / "qml"))
    engine.setInitialProperties({
        "pluginUrl": QUrl.fromLocalFile(str(Path(args.plugin).resolve())),
        "pluginSettings": json.loads(args.settings),
    })
    engine.warnings.connect(lambda warnings: [print(item.toString(), file=sys.stderr) for item in warnings])
    engine.load(QUrl.fromLocalFile(str(HERE / "qml" / "Harness.qml")))
    if not engine.rootObjects():
        print("HARNESS_FAIL", file=sys.stderr)
        return 1

    harness = engine.rootObjects()[0]
    status = {"code": 0}
    steps = [step.strip() for step in args.do.split(",") if step.strip()]

    def capture():
        plugin = harness.property("plugin")
        store = harness.property("store")
        if plugin is None or store is None:
            print("HARNESS_FAIL", file=sys.stderr)
            status["code"] = 1
            app.quit()
            return
        if args.dump:
            Path(args.dump).parent.mkdir(parents=True, exist_ok=True)
            Path(args.dump).write_text(json.dumps(snapshot(plugin, store), indent=2, default=str))
        app.quit()

    def emit_snap():
        if not args.trace:
            return
        plugin = harness.property("plugin")
        store = harness.property("store")
        print("SNAP " + json.dumps(snapshot(plugin, store), default=str), flush=True)

    def run_next():
        emit_snap()
        if not steps:
            QTimer.singleShot(0, capture)
            return
        step = steps.pop(0)
        plugin = harness.property("plugin")
        store = harness.property("store")
        if plugin is None or store is None:
            print("HARNESS_FAIL", file=sys.stderr)
            status["code"] = 1
            app.quit()
            return
        delay = int(step.partition(":")[2]) if step.startswith("wait:") else args.step_delay
        try:
            apply_step(step, plugin, store)
        except Exception as error:
            print(f"HARNESS_FAIL {error}", file=sys.stderr)
            status["code"] = 1
            app.quit()
            return
        QTimer.singleShot(delay, run_next)

    QTimer.singleShot(args.settle, run_next)
    app.exec()
    return status["code"]


if __name__ == "__main__":
    raise SystemExit(main())
