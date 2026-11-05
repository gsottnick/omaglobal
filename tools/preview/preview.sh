#!/usr/bin/env bash
# Rebuild preview.png from the shipped daemon and the fake openconnect.
set -euo pipefail
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
root="$(CDPATH= cd -- "$here/../.." && pwd)"
exec python3 "$here/render_preview.py" "$root/preview.png"
