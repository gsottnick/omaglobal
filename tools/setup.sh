#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The one privileged step. The user runs this in their own terminal.
# It does not re-exec itself under sudo; each privileged command is prefixed
# so the user's sudo password prompt is the one they expect.
USAGE_LINE="tools/setup.sh"
set -euo pipefail

usage() {
  printf '%s\n' "$USAGE_LINE"
}

if [[ ${1:-} == "-h" || ${1:-} == "--help" ]]; then
  usage
  exit 0
fi

PIN="21cce40334791a533c7a263fe367f0ddc072d8fb"
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DATA="${XDG_DATA_HOME:-$HOME/.local/share}/gp-vpn"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/gp-vpn"

echo "pacman -S --needed openconnect python-requests python-gobject gtk3 gobject-introspection webkit2gtk-4.1 wl-clipboard git"
sudo pacman -S --needed --noconfirm openconnect python-requests python-gobject gtk3 gobject-introspection webkit2gtk-4.1 wl-clipboard git

echo "clone gp-saml-gui at ${PIN}"
mkdir -p "$DATA" "$CONFIG"
if [[ ! -d ${DATA}/gp-saml-gui/.git ]]; then
  git clone https://github.com/dlenski/gp-saml-gui.git "${DATA}/gp-saml-gui"
fi
git -C "${DATA}/gp-saml-gui" fetch --depth 1 origin "${PIN}"
git -C "${DATA}/gp-saml-gui" checkout --detach "${PIN}"
printf '{"gp-saml-gui":"%s"}\n' "$PIN" > "${CONFIG}/version.json"

echo "install gpvpnd and the systemd units"
sudo install -m 0755 "${ROOT}/bin/gpvpnd" /usr/local/bin/gpvpnd
sudo install -m 0644 "${ROOT}/tools/gp-vpn.service" /etc/systemd/system/gp-vpn.service
sudo install -m 0644 "${ROOT}/tools/gp-vpn.socket" /etc/systemd/system/gp-vpn.socket
sudo systemctl daemon-reload
sudo systemctl enable --now gp-vpn.socket

echo "verify"
systemctl is-active gp-vpn.socket
"${ROOT}/bin/gpvpn" setup-check
