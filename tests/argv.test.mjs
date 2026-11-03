import test from "node:test"
import assert from "node:assert/strict"
import path from "node:path"
import {
  COOKIE, SAML_OK, gpvpn, tempHome, writeSaml, run, startDaemon, stopDaemon, waitForDaemon, readText,
} from "./support.mjs"

async function connected(env, dir, mode) {
  const daemon = startDaemon(dir, env, mode)
  env.GPVPN_SOCKET = daemon.sock
  await waitForDaemon(daemon.sock)
  await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com", "--gateway", "vpn.example.com", "--gateway-name", "KEEP-EXAMPLE"], env)
  const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
  return { daemon, result }
}

test("openconnect argv is the fixed list and the cookie is only on stdin", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  const { daemon, result } = await connected(env, dir, "ok")
  try {
    assert.equal(result.code, 0, result.stderr)
    const argv = await readText(path.join(dir, "oc", "argv"))
    const stdin = await readText(path.join(dir, "oc", "stdin"))
    assert.equal(argv.includes(COOKIE), false)
    assert.match(argv, /--protocol=gp/)
    assert.match(argv, /--passwd-on-stdin/)
    assert.match(argv, /--non-inter/)
    assert.match(argv, /PAN GlobalProtect/)
    assert.match(argv, /linux-64/)
    assert.equal(stdin.trim(), COOKIE)
    const state = JSON.parse(result.stdout)
    assert.equal(state.gateway, "KEEP-EXAMPLE")
    assert.equal(state.server, "vpn.example.com")
    const groups = (await readText(path.join(dir, "oc", "usergroup.log"))).trim().split("\n").filter(Boolean)
    assert.deepEqual(groups, ["gateway:prelogin-cookie"])
    console.log("cookie absent from openconnect argv")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a failed connect retries once with the other interface string", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  const daemon = startDaemon(dir, env, "fail")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
    assert.notEqual(result.code, 0)
    assert.equal(result.stdout.includes(COOKIE), false)
    assert.equal(result.stderr.includes(COOKIE), false)
    const groups = (await readText(path.join(dir, "oc", "usergroup.log"))).trim().split("\n").filter(Boolean)
    assert.deepEqual(groups, ["gateway:prelogin-cookie", "portal:prelogin-cookie"])
    const launches = (await readText(path.join(dir, "oc", "argv.log"))).split("---").filter((part) => part.trim())
    assert.equal(launches.length, 2)
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a gateway failure retries onto the portal interface and then connects", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  const { daemon, result } = await connected(env, dir, "fail-gateway")
  try {
    assert.equal(result.code, 0, result.stderr)
    const groups = (await readText(path.join(dir, "oc", "usergroup.log"))).trim().split("\n").filter(Boolean)
    assert.deepEqual(groups, ["gateway:prelogin-cookie", "portal:prelogin-cookie"])
    assert.equal(JSON.parse(result.stdout).state, "connected")
  } finally {
    await stopDaemon(daemon.child)
  }
})
