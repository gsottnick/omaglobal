# Agents

PRs only. Do not commit to `main`.

Bump `manifest.json` `version` for anything a user receives. Test-only changes do not need a bump.

Do not restart or refresh the Omarchy shell. It hosts the lock screen.

Do not run `tools/setup.sh` (it uses the user's sudo). Exercise the daemon with `--socket` and `--openconnect` as the normal user.

Dev files stay untracked: virtualenvs, shell checkouts, and `tests/harness/.qsroot/`.

Plugin-specific notes belong in the `omaglobal` skill, not in the general omarchy-plugin skill.
