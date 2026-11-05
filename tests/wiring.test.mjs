import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import path from "node:path"
import { repo, gpvpn } from "./support.mjs"
import { spawnSync } from "node:child_process"

const read = (name) => readFile(path.join(repo, name), "utf8")

test("the setup card matches the setup script usage line", async () => {
  const setup = await read("tools/setup.sh")
  const usage = setup.match(/^USAGE_LINE="([^"]+)"/m)
  assert.ok(usage, "setup.sh declares USAGE_LINE")
  const popup = await read("OmaPopup.qml")
  const store = await read("OmaStore.qml")
  assert.match(store, /setupCommand: pluginRoot \+ "tools\/setup\.sh"/)
  assert.match(store, /function installSetup/)
  assert.match(store, /xdg-terminal-exec/)
  assert.match(popup, /objectName: "installSetup"/)
  assert.match(popup, /OmaStore\.installSetup\(\)/)
  assert.match(usage[1], /^tools\/setup\.sh$/)
  const readme = await read("README.md")
  assert.match(readme, new RegExp(usage[1].replace(/[.*+?^${}()|[\]\\]/g, "\\$&")))
  assert.match(setup, /webkit2gtk-4\.1/)
  assert.match(setup, /\bgtk3\b/)
  assert.match(setup, /gobject-introspection/)
  assert.match(setup, /wl-clipboard/)
  assert.match(popup, /objectName: "gatewayButton"/)
  // Re-running setup is how a plugin update reaches the daemon, so it must restart it.
  assert.match(setup, /systemctl stop gp-vpn\.service/)
})

test("every command the README tells the user to run exists", async () => {
  const readme = await read("README.md")
  const helper = await read("bin/gpvpn")
  const commands = [...readme.matchAll(/^gpvpn(?: ([a-z-]+))?/gm)].map((match) => match[1] || "")
  assert.ok(commands.length >= 4)
  for (const command of commands) {
    if (!command) continue
    assert.match(helper, new RegExp(`"${command}"`))
  }
  assert.match(await read("tools/gp-vpn.socket"), /ListenStream=\/run\/gp-vpn\/ctrl\.sock/)
  assert.match(await read("tools/gp-vpn.service"), /ExecStart=\/usr\/local\/bin\/gpvpnd/)
  const checked = spawnSync(gpvpn, ["setup-check"], {
    encoding: "utf8",
    env: { ...process.env, GPVPN_SOCKET: "/run/gp-vpn/omaglobal-missing.sock" },
  })
  assert.equal(checked.status, 4)
  assert.match(checked.stderr, /tools\/setup\.sh/)
})

test("the panel keeps the theme rules that both shells enforce", async () => {
  const panel = await read("Panel.qml")
  const popup = await read("OmaPopup.qml")
  const store = await read("OmaStore.qml")
  const head = panel.slice(0, panel.indexOf("BarIconButton"))
  assert.doesNotMatch(head, /\bdimmed\s*:/)
  assert.match(panel, /dimmed:\s*root\.iconDimmed/)
  assert.match(panel, /Color\.urgent/)
  assert.doesNotMatch(panel + popup + store, /Color\.error/)
  assert.doesNotMatch(panel + popup + store, /#[0-9A-Fa-f]{3,8}\b/)
  assert.match(panel, /advanceWidth/)
  assert.doesNotMatch(panel + popup, /horizontalAdvance/)
  assert.equal((panel.match(/\bTimer\b/g) || []).length, 1)
  assert.equal((popup.match(/\bTimer\b/g) || []).length, 0)
  assert.equal((store.match(/\bTimer\b/g) || []).length, 2)
  assert.match(store, /id:\s*retryTimer/)
  assert.match(store, /id:\s*clockTimer/)
  // Install progress is watched through a file, never a timer.
  assert.match(store, /FileView\s*\{/)
  assert.match(store, /watchChanges:\s*true/)
  assert.doesNotMatch(panel + popup + store, /setInterval|sudo|pkexec/)
  assert.match(panel, /Component\.onCompleted:\s*applySettings/)
  assert.match(panel, /onSettingsChanged:\s*applySettings/)
  assert.match(popup, /textFormat:\s*Text\.PlainText/)
})
