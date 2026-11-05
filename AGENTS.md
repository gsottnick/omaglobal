# Agents

PRs only. Do not commit to `main`.

Bump `manifest.json` `version` for anything a user receives. Test-only changes do not need a bump.

Do not restart or refresh the Omarchy shell. It hosts the lock screen.

Do not run `tools/setup.sh` (it uses the user's sudo). Exercise the daemon with `--socket` and `--openconnect` as the normal user.

Dev files stay untracked: virtualenvs, shell checkouts, and `tests/harness/.qsroot/`.

Plugin-specific notes belong in the `omaglobal` skill, not in the general omarchy-plugin skill.

Test fixtures print what the real tools print. `tests/fixtures/fake-openconnect` and `SAML_OK` come from openconnect 9.21 and the pinned gp-saml-gui source; never write a line there from memory.

UI checks use the harness `mouse:` step, a real click at the control's position, then `expect:` on what changed. `click:` only emits the signal and cannot catch a dead control.
