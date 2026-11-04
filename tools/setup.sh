#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One-privileged-step setup for first-time users. Reports progress to a JSON
# status file so the dropdown widget can show what's happening.
set -euo pipefail

USAGE_LINE="tools/setup.sh"
CURRENT_STEP=""

usage() { printf '%s\n' "$USAGE_LINE"; }
if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then usage; exit 0; fi

PIN="${GP_SAML_GIT_PIN:-21cce40334791a533c7a263fe367f0ddc072d8fb}"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/gp-vpn"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/gp-vpn"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/gp-vpn"
STATUS="$STATE/install.json"

mkdir -p "$STATE"

atomic_status() {
  local tmp; tmp=$(mktemp -p "$STATE" .status.XXXXXX)
  printf '%s\n' "$1" > "$tmp" && mv -f "$tmp" "$STATUS"
}

trap 'atomic_status "{\"status\":\"failed\",\"step\":\"${CURRENT_STEP}\",\"error\":\"Setup failed. Check the message above for details and press Install again.\"}" >&2; exit 1' ERR

atomic_status '{"status":"running","step":"packages","detail":"Checking what needs to be installed…"}'

# Step 1: packages
CURRENT_STEP=packages
echo "Step 1 of 4: Installing required packages (openconnect, GTK, git …)"
sudo pacman -S --needed --noconfirm openconnect python-requests python-gobject gtk3 gobject-introspection webkit2gtk-4.1 wl-clipboard git
atomic_status '{"status":"running","step":"packages","detail":"Packages are ready."}'

# Step 2: login helper
CURRENT_STEP=login-helper
echo "Step 2 of 4: Setting up the VPN login helper (a small security tool)"
mkdir -p "$DATA" "$CONFIG"
if [[ ! -d ${DATA}/gp-saml-gui/.git ]]; then
  git clone "${GP_SAML_GIT_URL:-https://github.com/dlenski/gp-saml-gui.git}" "${DATA}/gp-saml-gui"
fi
git -C "${DATA}/gp-saml-gui" fetch --depth 1 origin "${PIN}"
git -C "${DATA}/gp-saml-gui" checkout --detach "${PIN}"
printf '{"gp-saml-gui":"%s"}\n' "$PIN" > "${CONFIG}/version.json"
atomic_status '{"status":"running","step":"login-helper","detail":"Login helper is installed."}'

# Step 3: systemd service
CURRENT_STEP=service
echo "Step 3 of 4: Installing the background VPN service"
sudo install -m 0755 "${ROOT}/bin/gpvpnd" /usr/local/bin/gpvpnd
sudo install -m 0644 "${ROOT}/tools/gp-vpn.service" /etc/systemd/system/gp-vpn.service
sudo install -m 0644 "${ROOT}/tools/gp-vpn.socket" /etc/systemd/system/gp-vpn.socket
sudo systemctl daemon-reload
sudo systemctl enable --now gp-vpn.socket
atomic_status '{"status":"running","step":"service","detail":"Service is installed and enabled."}'

# Step 4: verify
CURRENT_STEP=verify
echo "Step 4 of 4: Verifying everything is working"
systemctl is-active gp-vpn.socket
"${ROOT}/bin/gpvpn" setup-check
atomic_status '{"status":"done","step":"done"}'

echo ""
echo "Setup finished."
echo "Installed: VPN packages, login helper, background service"
echo "You can close this terminal now."
