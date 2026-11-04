# Security

OmaGlobal's control socket is a local trust boundary.

## What the socket can do

`/run/gp-vpn/ctrl.sock` is mode `0660` and group `wheel`, created by `gp-vpn.socket`. Anyone who can connect can ask the daemon to start or stop the one tunnel. They cannot ask it to run an arbitrary program.

The daemon execs `openconnect` from an argument list. Base flags are fixed: protocol, user agent, user, OS, usergroup, `--passwd-on-stdin`, `--non-inter`, and the server. Anything the dropdown's Advanced screen adds comes through a whitelist validated at the daemon, one flag at a time. The daemon reads the connecting process's Unix socket credentials (`SO_PEERCRED`) to determine its uid and gid, then applies per-file ownership rules:

- **Admin-installed scripts** (`--csd-wrapper`, `--script`): the resolved path must be owned by root (uid 0), have no group/other write bit, and every parent directory up to `/` must also be root-owned with no group/other write bit. Additionally, `--csd-user=<username>` is appended so openconnect drops privileges to the connecting user for the HIP script.
- **User files** (`--cafile`, `--certificate`, `--sslkey`): the resolved file must be owned by the connecting user or by root, and the connecting user must have read permission based on ownership and mode bits. Symlink escapes are prevented via `os.path.realpath`.
- When peer credentials are unavailable (e.g. systemd socket activation), file and script options are refused.

Unknown keys are refused, bad values are refused, and nothing is ever a shell string. The cookie or password is written to openconnect's stdin; `/proc/<pid>/cmdline` never sees it.

Password sign-in puts the password in the same channel as the cookie: the widget writes it to the helper's stdin, the helper to the socket, the daemon to openconnect's stdin. It is not stored anywhere.

## What is not on the command line

The helper spawns the login tool from an argument list. It does not build a shell string. The cookie moves from the login tool's output, through the helper, onto the socket, and into openconnect's stdin. Logs and error text pass through a filter that strips cookie-shaped tokens before they are queued. The bar stores none of the cookie. Notifications are posted by `gpvpn notify`, which reads the text on stdin. The default notification does not include the username.

## What setup does

`tools/setup.sh` is the only privileged step. The dropdown's Install button opens your terminal and runs that script; you approve the password there. The widget and the helper do not call sudo or pkexec. The script installs packages, a pinned gp-saml-gui checkout, and the systemd unit, writing progress to `~/.local/state/gp-vpn/install.json` (plain status text, no secrets). Review it before you run it.

## What this does not protect

A local account in group `wheel` can send its own cookie or password to the daemon, and can supply Advanced options through the socket with the same validation you get from the UI. Do not widen the socket mode. Admin-installed script paths (`--csd-wrapper`, `--script`) require root-owned path chains, so a normal user cannot exploit them. User file paths (`--cafile`, `--certificate`, `--sslkey`) are restricted to files the connecting user owns or can read. The login cookie is a bearer token for the gateway for as long as the gateway says it is; the daemon forgets it after handing it to openconnect. Profiles live in your config directory (mode `0600`) and contain the portal, username, and advanced settings, not the cookie or password.

The reusable login session is the cookie jar under the cache directory `gp-vpn/`. That directory is mode `0700` and the jar is mode `0600`. A second `gpvpnd` will not unlink a control socket that is already accepting connections. The daemon process itself runs as root, because it has to start the tunnel. The unit does not add a sandbox. Admin-installed scripts (`--csd-wrapper`, `--script`) must be root-owned with no group/other write anywhere in the path chain; `--csd-user` drops privileges to the connecting user before running the HIP script. User files (`--cafile`, `--certificate`, `--sslkey`) must be readable by the connecting user — symlink escapes are blocked by `realpath`. The `--sslkey` option can only accept files the connecting user owns or can read, preventing access to root-only files like `/etc/shadow`.
