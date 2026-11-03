import test from "node:test"
import assert from "node:assert/strict"
import { gpvpn, tempHome, run } from "./support.mjs"

test("profiles round-trip and mode is always gateway", async () => {
  const { env } = await tempHome()
  const first = await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  assert.equal(first.code, 0)
  const second = await run(gpvpn, ["profile", "add", "--name", "Other"], env)
  assert.equal(second.code, 0)
  const listed = JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
  assert.equal(listed.profiles.length, 2)
  const other = listed.profiles.find((item) => item.name === "Other")
  assert.equal(other.portal, "vpn.example.com")
  assert.equal(other.username, "user@example.com")
  assert.equal(other.mode, "gateway")
  assert.equal(other.gateway, "")
  const forced = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "mode", "portal"], env)).stdout)
  assert.equal(forced.profiles.find((item) => item.name === "Other").mode, "gateway")
  const named = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "gatewayName", "KEEP-EXAMPLE"], env)).stdout)
  assert.equal(named.profiles.find((item) => item.name === "Other").gatewayName, "KEEP-EXAMPLE")
  const active = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "active", "yes"], env)).stdout)
  assert.equal(active.active, "Other")
  const removed = JSON.parse((await run(gpvpn, ["profile", "remove", "Other"], env)).stdout)
  assert.equal(removed.profiles.length, 1)
  assert.equal(removed.profiles[0].name, "Default")
  console.log("profile round-trip")
})
