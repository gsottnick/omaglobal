# Contributing

Open a pull request. Do not push to `main`.

Run `node --test tests/*.test.mjs` and `omarchy plugin validate` on a copy of the tree that contains no symlinks. The panel harness needs PySide6 `>=6.10,<6.12` and `OMARCHY_SHELL` pointed at a checkout of the shell you claim to support.

Do not add real portals, cookies, usernames, or home paths. Fixtures use `vpn.example.com` and `user@example.com`.
