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
  const motion = await read("ShieldMotion.qml")
  const mark = await read("ShieldMark.qml")
  assert.match(motion, /Color\.urgent/)
  assert.doesNotMatch(panel + popup + store + motion + mark, /Color\.error/)
  assert.doesNotMatch(panel + popup + store + motion + mark, /#[0-9A-Fa-f]{3,8}\b/)
  // Qt 6.12 ships its own Color type. The harness runs 6.11 and cannot see this.
  for (const text of [panel, popup, motion, mark]) assert.doesNotMatch(text, /(?<![.\w])Color\./)
  // Motion runs on the display's clock and honors the reduced-motion setting.
  assert.doesNotMatch(panel + popup + motion + mark, /\bTimer\b/)
  assert.match(motion, /!Style\.reduceMotion/)
  assert.match(panel, /advanceWidth/)
  assert.doesNotMatch(panel + popup, /horizontalAdvance/)
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

test("shield colors come from what a theme color is, not its slot", async () => {
  const source = (await read("shieldColors.js")).replace(".pragma library", "")
  const colors = new Function(`${source}; return { signal }`)()
  const signals = (text) => [colors.signal(text, "green", 140, 50, "ok"), colors.signal(text, "yellow", 38, 26, "busy"), colors.signal(text, "red", 0, 25, "fail")]
  // Scrambled slots: color1 is lime, color2 is red.
  const scrambled = `accent = "#BE3F50"\nforeground = "#14B9B5"\ncolor1 = "#c8e967"\ncolor2 = "#E20342"\ncolor3 = "#7cd699"\ncolor6 = "#FF7F41"\ncolor10 = "#f93d3b"\ncolor14 = "#ffbe74"\n`
  assert.deepEqual(signals(scrambled), ["#7cd699", "#ffbe74", "#f93d3b"])
  // A conventional palette.
  const plain = `color1 = "#f38ba8"\ncolor2 = "#a6e3a1"\ncolor3 = "#f9e2af"\ncolor4 = "#89b4fa"\n`
  assert.deepEqual(signals(plain), ["#a6e3a1", "#f9e2af", "#f38ba8"])
  // A named color wins, even one the hue search would miss.
  assert.deepEqual(signals(`green = "#9ece6a"\nyellow = "#e0af68"\nred = "#f7768e"\ncyan = "#449dab"\n`), ["#9ece6a", "#e0af68", "#f7768e"])
  // A monochrome theme has none, so the theme's own roles stand in.
  const mono = `color1 = "#888888"\ncolor2 = "#aaaaaa"\naccent = "#cccccc"\n`
  assert.deepEqual(signals(mono), ["ok", "busy", "fail"])
})
