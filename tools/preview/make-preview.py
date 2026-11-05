#!/usr/bin/env python3
"""Rebuild preview.png, the marketplace and README picture.

Renders the real dropdown against the fake daemon (made-up VPNs only) in the
Tokyo Night theme at 2.5x size, then lays the shots out with preview.html and
screenshots that page with headless Chromium at 3840x2160. Needs the test venv
(see AGENTS.md) and chromium.

    .venv-harness/bin/python tools/preview/make-preview.py
"""

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tests" / "harness"))
sys.argv = sys.argv[:1]
import drive  # noqa: E402
from PySide6.QtGui import QImage  # noqa: E402

GATEWAYS = [{"name": "US-East", "host": "east.example.com", "priority": 1},
            {"name": "US-West", "host": "west.example.com", "priority": 2}]


def render(env: dict, sock: str, steps: list) -> None:
    done = subprocess.run(
        [sys.executable, str(drive.MAIN), "--omarchy", "/usr/share/omarchy/shell",
         "--theme", "tokyo-night", "--font-size", "30", "--settings", json.dumps(drive.BASE_SETTINGS),
         "--do", ",".join(steps), "--settle", "900", "--step-delay", "250"],
        env={**env, "HARNESS_SCREEN": "4000x3000", "HARNESS_ALLOW_OVERLAPS": "1", "GPVPN_SOCKET": sock},
        text=True, capture_output=True, check=False,
    )
    if done.returncode != 0 or "STEP FAILED" in done.stdout + done.stderr:
        raise SystemExit(done.stdout[-800:] + done.stderr[-800:])


def main() -> int:
    chromium = shutil.which("chromium") or shutil.which("google-chrome-stable")
    if not chromium:
        print("needs chromium", file=sys.stderr)
        return 1
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        sock = str(work / "run" / "ctrl.sock")
        env = drive.ready_env(str(work), sock)
        drive.seed(env,
                   ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"],
                   ["profile", "add", "--name", "School", "--portal", "vpn.example.edu"],
                   ["profile", "add", "--name", "Home lab", "--portal", "vpn.example.net"],
                   ["profile", "set", "Work", "gateways", json.dumps(GATEWAYS)],
                   ["profile", "set", "Work", "active", "yes"])
        fake = drive.start_fake(sock)
        try:
            render(env, sock, ["open", "screen:main", "wait:700",
                               f"itemshot:heroShield:{work / 'state-off.png'}",
                               "push:auth", "wait:1000", f"itemshot:heroShield:{work / 'state-busy.png'}",
                               "push:failed", "wait:1400", f"itemshot:heroShield:{work / 'state-fail.png'}",
                               "push:preview", "wait:1800", f"itemshot:heroShield:{work / 'state-on.png'}",
                               f"panelshot:{work / 'connected.png'}"])
            render(env, sock, ["open", "screen:main", "wait:400", "mouse:profileEditButton", "screen:editor",
                               "mouse:editorAdvancedToggle", "wait:500", "prop:vpnPopup:editorScrollTo=430",
                               "wait:900", f"panelshot:{work / 'options.png'}"])
        finally:
            drive.stop_fake(fake)
        # The shield shots carry the dropdown's background, so the tiles use it too.
        tile = QImage(str(work / "state-off.png")).pixelColor(1, 1)
        page = (HERE / "preview.html").read_text(encoding="utf-8")
        (work / "preview.html").write_text(page.replace("TILE", tile.name()), encoding="utf-8")
        subprocess.run(
            [chromium, "--headless=new", f"--user-data-dir={work / 'profile'}",
             "--disable-gpu", "--hide-scrollbars", "--window-size=1920,1080",
             "--force-device-scale-factor=2", "--virtual-time-budget=3000",
             f"--screenshot={REPO / 'preview.png'}", (work / "preview.html").as_uri()],
            check=True, capture_output=True,
        )
    print(REPO / "preview.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
