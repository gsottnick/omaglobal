# OmaGlobal

![OmaGlobal in the Omarchy bar](preview.png)

Any GlobalProtect VPN, in the Omarchy bar: work, school, or your own. Type the portal address once, press Connect, sign in when the window appears, done. No command line after that.

OmaGlobal is not affiliated with Palo Alto Networks or the GP Connect app.

## Setup

1. Add the plugin to the bar.
2. Click its icon and press **Install**. A terminal opens and asks for your password once. When it says `Setup finished.`, you can close it. The dropdown moves on by itself.
3. On the welcome screen, type your VPN portal address (like `vpn.example.com`) and press **Connect**. Sign in when the window appears. If you don't know it, ask whoever runs the VPN for the "GlobalProtect portal address".

That's it. The shield in the bar and in the dropdown move together: a line traces it while connecting, it fills with a tick when connected, and it shows an X if the connection fails. Its colors come from your Omarchy theme.

If an update brings a newer background service, the dropdown says so and shows **Update**. It asks for your password once, the same way Install does, and comes straight back.

## Using more than one VPN

Every portal you add shows up under "Your VPNs". Click one to switch: the old tunnel comes down and the new one comes up. Press **Edit** on any of them to rename it, set a different portal, pick a gateway, or remove it. The active one is the default that auto-connects (if you turn auto-connect on in the widget settings).

## What the dropdown shows while connecting

Three steps, in plain words: **Opening sign-in** (the sign-in window is coming up), **Signing in** (you may interact with it), **Starting tunnel**. When it lands, the card shows your VPN address, the gateway, how long you have been up, and how much data went through. **Disconnect** and **Reconnect** are right there. If something fails, the message says what happened and what to do next.

## Advanced options

Under **Edit → Advanced options** every openconnect setting that matters has a one-line explanation: gateway choice, portal vs gateway sign-in, password sign-in instead of SSO, the system type reported to the VPN, the host-check (HIP) script some gateways demand, server certificate pinning, custom certificate authorities, client certificates, tunnel packet size, TLS-only mode on networks that block UDP, reconnect patience, and a custom routing script. You only touch these when your VPN provider tells you to.

Sign-in is remembered between connections. **Forget saved sign-in** in the editor deletes it, so the next connect asks again.

## Known limits

- WebKitGTK can paint a blank sign-in window on Hyprland. OmaGlobal sets `GDK_BACKEND=x11` and `WEBKIT_DISABLE_DMABUF_RENDERER=1` so the window draws. That is a workaround, not a fix in WebKit or Hyprland. See UPSTREAM.md.
- Some gateways demand a Host Information Policy (HIP) report. OmaGlobal does not send one by default; if your gateway requires it, whoever runs it gives you a check script to put under Advanced options. For safety that script (and any custom routing script) must be installed by an admin: root-owned with safe permissions on the whole path. The HIP script itself runs as your user, never as root.
- A portal can hand back a cookie for the other interface. The connect retries once with the other interface string, then reports. It does not keep retrying.
- A portal with several gateways connects to the one it ranks best unless you pick one under **Edit**.
- Password sign-in cannot answer a one-time-code prompt. A VPN that needs one should use SSO.

## Optional: the command line

Everything above can also be done from a terminal. This is never required.

```
tools/setup.sh                 # the same install the Install button runs
gpvpn setup-check              # is the background service ready
gpvpn profile add --name Work --portal vpn.example.com
gpvpn connect --profile Work   # prompts/signs in as needed
gpvpn status
gpvpn disconnect
gpvpn profile list             # JSON, all profiles
gpvpn profile set Work noDtls On
gpvpn forget Work              # delete the saved sign-in
```

Uninstall: remove the widget from the bar, then `systemctl disable --now gp-vpn.socket gp-vpn.service`, delete `/usr/local/bin/gpvpnd` and the two `gp-vpn.*` units in `/etc/systemd/system`, run `sudo systemctl daemon-reload`, and delete `~/.local/share/gp-vpn`, `~/.config/gp-vpn`, `~/.cache/gp-vpn`, `~/.local/state/gp-vpn`.

## License

`bin/gpvpn`, `bin/gpvpnd`, and `tools/setup.sh` are GPL-3.0-or-later. The QML is MIT. `manifest.json` declares both.
