import test from "node:test"
import assert from "node:assert/strict"
import { readFile, writeFile, mkdir } from "node:fs/promises"
import path from "node:path"
import {
  COOKIE, SAML_OK, gpvpn, tempHome, writeSaml, run, startDaemon, stopDaemon, waitForDaemon, readText,
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

// ---- password-mode payload tests ----------------------------------------

test("password mode sends no cookie but has password on stdin", async () => {
  const { dir, env } = await tempHome()
  // Fake SAML script (won't be called in password mode)
  const samlScript = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  await writeFile(samlScript, `import sys; sys.exit(0)\n`)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    // Create password-mode profile
    await run(gpvpn, ["profile", "add", "--name", "PwProfile", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    await run(gpvpn, ["profile", "set", "PwProfile", "authMethod", "password"], env)
    // Connect with password via stdin
    const result = await run(gpvpn, ["connect", "--profile", "PwProfile"], env, "secretpass\n")
    assert.equal(result.code, 0, result.stderr + result.stdout)
    const state = JSON.parse(result.stdout)
    assert.equal(state.state, "connected")
    // Cookie must not appear anywhere
    assert.equal(result.stdout.includes(COOKIE), false)
    assert.equal(result.stderr.includes(COOKIE), false)
    // Password is on stdin, not argv
    const stdinContent = (await readText(path.join(dir, "oc", "stdin"))).trim()
    assert.equal(stdinContent, "secretpass")
    const argvContent = await readText(path.join(dir, "oc", "argv"))
    assert.equal(argvContent.includes("secretpass"), false)
    console.log("password-mode: no cookie, password on stdin")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("options are built only from set fields and passed to daemon", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_OK)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    // Create profile with some options but not all
    await run(gpvpn, ["profile", "add", "--name", "OptsProfile", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    await run(gpvpn, ["profile", "set", "OptsProfile", "os", "win"], env)
    await run(gpvpn, ["profile", "set", "OptsProfile", "noDtls", "On"], env)
    // Connect — should pass options even in SSO mode (daemon validates)
    const result = await run(gpvpn, ["connect", "--profile", "OptsProfile"], env)
    assert.equal(result.code, 0, result.stderr + result.stdout)
    const state = JSON.parse(result.stdout)
    assert.equal(state.state, "connected")
    // Verify the fake openconnect received the options
    const argvContent = await readText(path.join(dir, "oc", "argv"))
    assert.ok(argvContent.includes("--os"), `expected --os in argv: ${argvContent}`)
    assert.ok(argvContent.includes("win"), `expected win in argv: ${argvContent}`)
    assert.ok(argvContent.includes("--no-dtls"), `expected --no-dtls in argv: ${argvContent}`)
    console.log("options passed through to daemon")
  } finally {
    await stopDaemon(daemon.child)
  }
})


test("saml endpoint follows the profile interface", async () => {
  const { spawnSync } = await import("node:child_process")
  const { repo } = await import("./support.mjs")
  const { readFile } = await import("node:fs/promises")
  const source = await readFile(new URL("../bin/gpvpn", import.meta.url), "utf8")
  // The helper picks -p for portal and falls back to -g (gateway).
  assert.match(source, /endpoint = "-p" if interface == "portal" else "-g"/)
})
