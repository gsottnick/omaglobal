import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import {
  COOKIE, SAML_OK, gpvpn, tempHome, writeSaml, run, startDaemon, stopDaemon, waitForDaemon,
} from "./support.mjs"

test("a login block parses through gpvpn and the cookie stays off the output", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    const added = await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    assert.equal(added.code, 0)
    const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
    assert.equal(result.code, 0, result.stderr)
    assert.equal(result.stdout.includes(COOKIE), false)
    assert.equal(result.stderr.includes(COOKIE), false)
    const record = JSON.parse(await readFile(new URL(`file://${env.XDG_DATA_HOME}/saml-record.json`), "utf8"))
    assert.equal(record.env.GDK_BACKEND, "x11")
    assert.equal(record.env.WEBKIT_DISABLE_DMABUF_RENDERER, "1")
    assert.deepEqual(record.argv.slice(1, 5), ["-g", "--clientos", "Linux", "-C"])
    assert.match(record.argv[5], /okta-[0-9a-f]{8}\.json$/)
    assert.equal(record.argv[6], "vpn.example.com")
    assert.equal(record.argv.includes("-x"), false)
    assert.equal(record.argv.includes("-S"), false)
    assert.equal(record.argv.includes("-P"), false)
    assert.equal(record.argv.includes("-E"), false)
    const state = JSON.parse(result.stdout)
    assert.equal(state.state, "connected")
    assert.equal(state.ip, "172.16.8.8")
    console.log("both WebKit env vars set on the SSO spawn")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a parse miss exits 3 and does not print the cookie", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, `login closed\n${COOKIE}\n`)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
    assert.equal(result.code, 3)
    assert.equal(result.stdout.includes(COOKIE), false)
    assert.equal(result.stderr.includes(COOKIE), false)
    assert.match(result.stderr, /Could not read the login response/)
    console.log("parse-miss exit 3")
  } finally {
    await stopDaemon(daemon.child)
  }
})
