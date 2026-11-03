import test from "node:test"
import assert from "node:assert/strict"
import path from "node:path"
import { statSync } from "node:fs"
import { createHash } from "node:crypto"
import { writeFile } from "node:fs/promises"
import {
  COOKIE, SAML_OK, gpvpn, tempHome, writeSaml, run, startDaemon, stopDaemon, waitForDaemon, readText,
} from "./support.mjs"

function cookieJar(env, name) {
  const digest = createHash("sha256").update(name).digest("hex").slice(0, 8)
  return path.join(env.XDG_CACHE_HOME, "gp-vpn", `okta-${digest}.json`)
}

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
    const jar = cookieJar(env, "Default")
    assert.equal(statSync(jar).mode & 0o777, 0o600)
    assert.equal(statSync(path.dirname(jar)).mode & 0o777, 0o700)
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

test("a tunnel that is still coming up is not retried", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  env.GPVPN_CONNECT_TIMEOUT = "1"
  const daemon = startDaemon(dir, env, "hang")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
    assert.notEqual(result.code, 0)
    assert.equal(result.stderr.includes("Already connecting or connected"), false)
    const launches = (await readText(path.join(dir, "oc", "argv.log"))).split("---").filter((part) => part.trim())
    assert.equal(launches.length, 1)
    console.log("in-progress connect was not retried")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a slow tunnel still connects once", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  env.GPVPN_CONNECT_TIMEOUT = "8"
  const daemon = startDaemon(dir, env, "ok", { FAKE_OC_DELAY: "2" })
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com", "--gateway", "vpn.example.com", "--gateway-name", "KEEP-EXAMPLE"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
    assert.equal(result.code, 0, result.stderr)
    assert.equal(JSON.parse(result.stdout).state, "connected")
    const launches = (await readText(path.join(dir, "oc", "argv.log"))).split("---").filter((part) => part.trim())
    assert.equal(launches.length, 1)
    console.log("slow connect waited")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a missing WebKit library is not called a cancelled login", async () => {
  const { env } = await tempHome()
  const script = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  await writeFile(script, "import sys\nsys.stderr.write('ValueError: Namespace WebKit2 not available\\n')\nsys.exit(1)\n")
  await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
  assert.equal(result.code, 1)
  assert.match(result.stderr, /webkit2gtk-4\.1/)
  assert.equal(result.stderr.includes("Login cancelled"), false)
  console.log("missing WebKit names the package")
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
