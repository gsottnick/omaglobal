# OmaGlobal

Free GlobalProtect control from the Omarchy bar. Connect and disconnect, pick a gateway, sign in once through the system browser window, and let a cached session reconnect quietly. One-time setup is required. OmaGlobal is not affiliated with Palo Alto Networks or the GP Connect app.

The bar widget (MIT) talks to a small helper and daemon (GPL-3.0-or-later) over a local socket. The widget never asks for a password and never calls sudo. You run the setup script yourself, once.

## Setup

From this directory:

```
tools/setup.sh
```

That installs `openconnect` and the libraries the login window needs, clones the pinned gp-saml-gui, and starts the `gp-vpn.socket` systemd unit. Then add a profile and connect:

```
gpvpn setup-check
gpvpn profile add --name Default --portal vpn.example.com --username user@example.com
gpvpn profile list
gpvpn connect --profile Default
gpvpn status
gpvpn disconnect
```

Replace the portal and username with yours. They stay in `gp-vpn/profiles.json` under your config directory, not in the bar.

After a connection, the dropdown lists that portal's gateways. Automatic keeps the portal's choice. A gateway you pick is used the next time you connect.

Until the socket exists, the bar dropdown shows only that setup command and a Copy button.

## Uninstall

```
systemctl disable --now gp-vpn.socket gp-vpn.service
sudo rm /usr/local/bin/gpvpnd /etc/systemd/system/gp-vpn.service /etc/systemd/system/gp-vpn.socket
sudo systemctl daemon-reload
```

## Settings

Auto-connect, connect notifications, drop notifications, the VPN address in the bar, and the username in notifications are On/Off switches in the widget settings. The username switch is off. Notifications never include the login cookie.

## Known limits

WebKitGTK can paint a blank login window on Hyprland. The helper sets `GDK_BACKEND=x11` and `WEBKIT_DISABLE_DMABUF_RENDERER=1` so the window can draw. That is a workaround, not a fix in WebKit or Hyprland.

Some gateways demand a HIP report. This version does not send one. If a gateway refuses the tunnel for that reason, the dropdown shows the daemon's message. See UPSTREAM.md.

A portal can hand back a cookie for the other interface. The helper retries that connect once with the other interface string, then reports the failure. It does not keep retrying.

## License

`bin/gpvpn`, `bin/gpvpnd`, and `tools/setup.sh` are GPL-3.0-or-later. The QML is MIT. `manifest.json` declares both.
