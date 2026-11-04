#!/usr/bin/env python3
"""Load the shipped OmaGlobal panel against one Omarchy shell tree."""

import argparse
import json
import os
import socket
import time
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

from PySide6.QtCore import Qt, QTimer, QUrl  # noqa: E402
from PySide6.QtGui import QImage, QPainter  # noqa: E402
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
        "rxBytes": 1730000000,
        "txBytes": 94000000,
        "iface": "tun0",
        "since": int(time.time()) - 600,
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


def find_item(item, name):
    """Depth-first over the visual tree. Repeater delegates are not always
    QObject-descendants of the plugin, so findChild misses them."""
    if item is None:
        return None
    if item.objectName() == name:
        return item
    for child in item.childItems():
        found = find_item(child, name)
        if found is not None:
            return found
    return None


def find_anywhere(plugin, name):
    target = find_item(plugin, name)
    if target is not None:
        return target
    from PySide6.QtGui import QGuiApplication

    for window in QGuiApplication.allWindows():
        content = window.contentItem() if hasattr(window, "contentItem") else None
        target = find_item(content, name)
        if target is not None:
            return target
    return None


def read_prop(obj, name, default=None):
    if obj is None:
        return default
    value = obj.property(name)
    return default if value is None else value


def snapshot(plugin, store):
    from PySide6.QtCore import QObject

    button = plugin.findChild(type(plugin), "barButton") if plugin is not None else None
    # findChild with a type filter misses sibling types; search by name.
    button = None
    phase_text = ""
    if plugin is not None:
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
        "screen": read_prop(store, "screen", "") if store is not None else "",
        "stepText": read_prop(store, "stepText", "") if store is not None else "",
        "installStatus": read_prop(store, "installStatus", "") if store is not None else "",
        "installError": read_prop(store, "installError", "") if store is not None else "",
        "activeAuthMethod": read_prop(store, "activeAuthMethod", "") if store is not None else "",
        "rxBytes": read_prop(store, "rxBytes", 0) if store is not None else 0,
        "txBytes": read_prop(store, "txBytes", 0) if store is not None else 0,
        "askPassword": read_prop(
            plugin.findChild(QObject, "passwordCard") if plugin is not None else None,
            "visible", None),
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
    elif name == "click":
        from PySide6.QtCore import QObject

        target = find_anywhere(plugin, argument)
        if target is None:
            from PySide6.QtCore import QObject as _Q
            qnames = sorted({item.objectName() for item in plugin.findChildren(_Q) if item.objectName()})
            print("QNAMES " + ",".join(qnames))
            profiles = read_prop(store, "profiles", []) if store is not None else []
            try:
                names = [str(p.get("name")) for p in profiles.toVariant()]
            except AttributeError:
                names = "raw:%r" % profiles
            print("PROFILES %r screen=%s" % (names, read_prop(store, "screen", "")))
        if target is None:
            def walk(item):
                names = []
                if item.objectName():
                    names.append(item.objectName())
                for child in item.childItems():
                    names.extend(walk(child))
                return names
            from PySide6.QtGui import QGuiApplication as _App
            for w in _App.allWindows():
                obj = w if hasattr(w, "childItems") else None
                try:
                    root_item = w.contentItem() if hasattr(w, "contentItem") else None
                    names = walk(root_item) if root_item is not None else ["<no contentItem>"]
                except Exception:
                    names = ["<walk failed>"]
                print("VISUAL win %s: %s" % (w, ",".join(names[:60])))
            raise SystemExit(f"clickable missing: {argument}")
        clicked = getattr(target, "clicked", None)
        if clicked is None:
            raise SystemExit(f"{argument} has no clicked signal")
        clicked.emit()
    elif name == "prop":
        from PySide6.QtCore import QObject

        object_name, _, rest = argument.partition(":")
        prop_name, _, value = rest.partition(":")
        target = find_anywhere(plugin, object_name)
        if target is None:
            raise SystemExit(f"prop target missing: {object_name}")
        if value in ("true", "false"):
            target.setProperty(prop_name, value == "true")
        else:
            target.setProperty(prop_name, int(value) if value.lstrip("-").isdigit() else value)
    elif name == "waitScreen":
        from PySide6.QtCore import QEventLoop, QTimer

        # Test-side only: block until the store reaches a screen. The widget
        # itself waits on events, never polls.
        deadline = time.time() + 10
        while time.time() < deadline:
            if read_prop(store, "screen", "") == argument:
                return
            loop = QEventLoop()
            QTimer.singleShot(100, loop.quit)
            loop.exec()
        raise SystemExit(f"screen never became {argument}")
    elif name == "shot":
        from PySide6.QtGui import QGuiApplication

        out = Path(argument)
        out.parent.mkdir(parents=True, exist_ok=True)
        windows = [w for w in QGuiApplication.allWindows() if w.isVisible()]
        images = [w.grabWindow() for w in windows if not w.grabWindow().isNull()]
        images = [img for img in images if img.width() > 1 and img.height() > 1]
        if not images:
            raise SystemExit("no visible window to shoot")
        image = images[0]
        for extra in images[1:]:
            combined = QImage(max(image.width(), extra.width()), image.height() + extra.height() + 8, QImage.Format_ARGB32)
            combined.fill(Qt.transparent)
            painter = QPainter(combined)
            painter.drawImage(0, 0, image)
            painter.drawImage(0, image.height() + 8, extra)
            painter.end()
            image = combined
        image.save(str(out))
        print(f"SHOT {out}", flush=True)
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
