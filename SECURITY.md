# Security

OmaGlobal's control socket is a local trust boundary.

## What the socket can do

`/run/gp-vpn/ctrl.sock` is mode `0660` and group `wheel`, created by `gp-vpn.socket`. Anyone who can connect can ask the daemon to start or stop the one tunnel. They cannot ask it to run an arbitrary program. The daemon execs `openconnect` with a fixed argument list: protocol, user agent, user, OS, usergroup, `--passwd-on-stdin`, `--non-inter`, and the server. The prelogin cookie is written to that process's stdin and is not a command-line argument (`/proc/<pid>/cmdline` is world-readable).

## What is not on the command line

The helper spawns the login tool from an argument list. It does not build a shell string. The cookie moves from the login tool's output, through the helper, onto the socket, and into openconnect's stdin. Logs and error text pass through a filter that strips cookie-shaped tokens before they are queued. The bar stores none of the cookie. Notifications are posted by `gpvpn notify`, which reads the text on stdin. The default notification does not include the username.

## What setup does

`tools/setup.sh` is the only privileged step, and only because you run it. The widget and the helper do not call sudo or pkexec. The script installs packages, a pinned gp-saml-gui checkout, and the systemd unit. Review it before you run it.

## What this does not protect

A local account in group `wheel` can send its own cookie to the daemon. Do not widen the socket mode. The login cookie is a bearer token for the gateway for as long as the gateway says it is; the daemon forgets it after handing it to openconnect. Profiles live in your config directory and contain the portal and username, not the cookie.
