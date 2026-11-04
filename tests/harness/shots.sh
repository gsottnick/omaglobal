#!/usr/bin/env bash
# Drive the real panel through every screen and save a PNG per screen.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$(dirname "$HERE")")"
PY="$REPO/.venv-harness/bin/python"
MAIN="$HERE/main.py"
OUT="${1:-/tmp/opencode/omaglobal-shots-r2}"
SHELL_DIR="${2:-/usr/share/omarchy/shell}"
rm -rf "$OUT"
mkdir -p "$OUT"

ROOT="$(mktemp -d -p /tmp/opencode omaglobal-xdg-XXXX)"
for key in config cache data state run; do mkdir -p "$ROOT/$key"; done
SOCK="$ROOT/run/ctrl.sock"

# Fake git that claims the pinned gp-saml-gui checkout, so `gpvpn deps`
# reports ready without a network. A fixture gp_saml_gui.py satisfies the
# file check without any network.
FIXBIN="$ROOT/bin"
mkdir -p "$FIXBIN"
cat > "$FIXBIN/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" || "${1:-}" == "rev-parse" ]]; then
  echo "21cce40334791a533c7a263fe367f0ddc072d8fb"
  exit 0
fi
exec /usr/bin/git "$@"
EOF
chmod +x "$FIXBIN/git"
SAML="$ROOT/data/gp-vpn/gp-saml-gui/gp_saml_gui.py"
mkdir -p "$(dirname "$SAML")"
printf '#!/usr/bin/env python3\n' > "$SAML"

GPVPN="$REPO/bin/gpvpn"
seed() {
  GPVPN_SOCKET="$SOCK" XDG_CONFIG_HOME="$ROOT/config" "$GPVPN" profile add \
    --name "$1" --portal "$2" ${3:+--username "$3"} >/dev/null
}

env_common() {
  env \
    HARNESS_SCREEN=900x1700 \
    QT_QPA_PLATFORM=offscreen \
    XDG_CONFIG_HOME="$ROOT/config" XDG_CACHE_HOME="$ROOT/cache" \
    XDG_DATA_HOME="$ROOT/data" XDG_STATE_HOME="$ROOT/state" \
    XDG_RUNTIME_DIR="$ROOT/run" PATH="$FIXBIN:$PATH" "$@"
}

run() {
  env_common GPVPN_SOCKET="$SOCK" "$PY" "$MAIN" \
    --omarchy "$SHELL_DIR" --plugin "$REPO/Panel.qml" \
    --settle 800 --step-delay 300 --do "$1" >/dev/null 2>"$ROOT/last.log"
}

# Scenarios 1-3 run before the daemon exists: point the socket at a path
# that stays missing even where the host has the real unit installed.
run_nosock() {
  env_common GPVPN_SOCKET="$ROOT/run/missing.sock" "$PY" "$MAIN" \
    --omarchy "$SHELL_DIR" --plugin "$REPO/Panel.qml" \
    --settle 900 --step-delay 300 --do "$1" >/dev/null
}

echo "== 1 setup (no socket)"
run_nosock "open,wait:700,shot:$OUT/01-setup.png"

echo "== 2 installing"
mkdir -p "$ROOT/state/gp-vpn"
printf '{"status":"running","step":"packages","detail":"Installing the VPN tunnel and sign-in window."}\n' \
  > "$ROOT/state/gp-vpn/install.json"
run_nosock "open,wait:700,shot:$OUT/02-installing.png"

echo "== 3 install failed"
printf '{"status":"failed","step":"packages","error":"The package manager could not reach the servers. Check the internet and try again."}\n' \
  > "$ROOT/state/gp-vpn/install.json"
run_nosock "open,wait:700,shot:$OUT/03-install-failed.png"

echo "== 4 welcome"
( "$PY" "$HERE/fake_socket.py" "$SOCK" >/dev/null 2>&1 & echo $! > "$ROOT/fake.pid" ) 2>/dev/null
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 0.05; done
run "open,waitScreen:welcome,wait:500,shot:$OUT/04-welcome.png"

echo "== 5 multiple VPNs"
seed "Work" "vpn.example.org"
seed "Personal" "vpn.example.net"
run "open,waitScreen:main,wait:500,shot:$OUT/09-vpns.png"

echo "== 6 connecting steps + connected + error"
run "open,waitScreen:main,push:auth,wait:500,shot:$OUT/05-signing-in.png,push:connecting,wait:400,shot:$OUT/06-starting-tunnel.png,push:connected,wait:600,shot:$OUT/07-connected.png,push:failed,wait:500,shot:$OUT/08-error.png"

echo "== 7 editor + advanced"
run "open,waitScreen:main,click:profileEditButton,wait:600,shot:$OUT/10-editor-top.png,click:editorAdvancedToggle,wait:800,shot:$OUT/10b-advanced-open.png"
run "open,waitScreen:main,click:profileEditButton,wait:600,click:editorAdvancedToggle,wait:800,prop:vpnPopup:editorScrollTo=260,wait:1500,shot:$OUT/11-editor-middle.png,prop:vpnPopup:editorScrollTo=620,wait:1500,shot:$OUT/11b-editor-low.png,prop:vpnPopup:editorScrollTo=1100,wait:1500,shot:$OUT/11c-editor-bottom.png,prop:vpnPopup:editorScrollTo=1750,wait:1200,click:editorRemove,wait:400,shot:$OUT/11d-remove-armed.png"

echo "== 7c manage section"
run "open,waitScreen:main,click:profileEditButton,wait:600,click:editorAdvancedToggle,wait:600,prop:vpnPopup:editorScrollTo=1750,wait:1200,click:editorRemove,wait:400,shot:$OUT/13-manage.png"

echo "== 8 password prompt"
GPVPN_SOCKET="$SOCK" XDG_CONFIG_HOME="$ROOT/config" "$GPVPN" profile set Work authMethod password >/dev/null
GPVPN_SOCKET="$SOCK" XDG_CONFIG_HOME="$ROOT/config" "$GPVPN" profile set Work active yes >/dev/null
run "open,waitScreen:main,click:vpnConnectButton,wait:600,shot:$OUT/12-password.png"

echo "shots in $OUT"
ls -la "$OUT"
