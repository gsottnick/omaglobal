# Upstream limits

These are not fixed here. The widget surfaces them; it does not pretend they are gone.

## K1 — WebKitGTK on Hyprland

WebKitGTK can render a blank page on Hyprland, and an unset `GDK_BACKEND` can crash the login window with a Gdk protocol error. `gpvpn` sets `GDK_BACKEND=x11` and `WEBKIT_DISABLE_DMABUF_RENDERER=1` before it starts the login helper. If a newer WebKitGTK draws correctly without those, the variables are harmless. This is not a Hyprland or WebKit patch.

## K2 — HIP reports

openconnect can warn that VPN connectivity may be limited without a HIP report. gp-saml-gui does not produce one, and this version does not emulate one. A gateway that hard-requires HIP will reject the tunnel. The dropdown shows the daemon's message, including that warning when it is the failure text.

## K3 — Portal versus gateway cookie

A portal can return a `portal-userauthcookie` even when the login helper was started with `-g`. On a failed connect, `gpvpn` retries once with the other interface string (`gateway` or `portal`) and the same cookie, then reports the failure. It does not loop. A gateway that accepts neither interface still fails.
