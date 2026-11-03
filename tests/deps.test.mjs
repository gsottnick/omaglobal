import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { repo, gpvpn, tempHome, run } from "./support.mjs"

test("deps lists every setup package and separates a missing service", async () => {
  const { env } = await tempHome()
  env.GPVPN_SOCKET = path.join(os.tmpdir(), `omaglobal-deps-missing-${process.pid}.sock`)
  const setup = await readFile(path.join(repo, "tools/setup.sh"), "utf8")
  const packages = setup.match(/^sudo pacman -S --needed --noconfirm ([^\n]+)/m)
  assert.ok(packages)
  const helper = await readFile(gpvpn, "utf8")
  const pin = helper.match(/SAML_PIN = "([0-9a-f]{40})"/)
  assert.ok(pin)
  assert.match(setup, new RegExp(pin[1]))

  const result = await run(gpvpn, ["deps"], env)
  assert.equal(result.code, 0)
  const report = JSON.parse(result.stdout)
  assert.equal(report.ready, false)
  const byName = new Map(report.items.map((item) => [item.name, item]))
  for (const name of packages[1].split(/\s+/)) {
    assert.equal(typeof byName.get(name)?.present, "boolean", name)
    assert.ok(byName.get(name).purpose)
  }
  assert.equal(byName.get("gp-saml-gui").present, false)
  assert.equal(byName.get("gp-vpn.socket").present, false)
  assert.equal(byName.get("gp-vpn.socket").required, true)
  assert.equal(byName.get("openconnect").required, true)
  assert.equal(byName.get("wl-clipboard").required, false)
})

test("deps sees a live service socket", async () => {
  const { env } = await tempHome()
  const sock = path.join(env.HOME, "ctrl.sock")
  const server = net.createServer()
  await new Promise((resolve) => server.listen(sock, resolve))
  try {
    env.GPVPN_SOCKET = sock
    const result = await run(gpvpn, ["deps"], env)
    assert.equal(result.code, 0)
    const report = JSON.parse(result.stdout)
    const service = report.items.find((item) => item.name === "gp-vpn.socket")
    assert.equal(service.present, true)
    assert.equal(report.ready, false)
  } finally {
    server.close()
  }
})
