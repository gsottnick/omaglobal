import assert from "node:assert/strict"
import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import crypto from "node:crypto"
import {
  COOKIE, SAML_OK, gpvpn, tempHome, writeSaml, run, startDaemon, stopDaemon, waitForDaemon, readText,
} from "./support.mjs"

const home = await tempHome()
const work = process.env.OMGLOBAL_E2E_DIR || home.dir
await mkdir(work, { recursive: true })
await writeSaml(home.env, SAML_OK)
const daemon = startDaemon(work, home.env, "ok", { FAKE_OC_SLEEP: "30" })
const pid = daemon.child.pid
home.env.GPVPN_SOCKET = daemon.sock

try {
  // ---- original SSO flow ------------------------------------------------
  await waitForDaemon(daemon.sock)
  const added = await run(gpvpn, [
    "profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com",
  ], home.env)
  assert.equal(added.code, 0, added.stderr)
  const result = await run(gpvpn, ["connect", "--profile", "Default"], home.env)
  assert.equal(result.code, 0, result.stderr + result.stdout)
  assert.equal(result.stdout.includes(COOKIE), false)
  assert.equal(result.stderr.includes(COOKIE), false)
  const state = JSON.parse(result.stdout)
  assert.equal(state.state, "connected")
  assert.equal(state.ip, "172.16.8.8")
  assert.equal(state.gateway, "PROD-EXAMPLE")
  assert.equal(state.expires, "2030-01-01T00:00:00")
  const argv = await readText(path.join(daemon.ocDir, "argv"))
  const stdin = (await readText(path.join(daemon.ocDir, "stdin"))).trim()
  assert.equal(argv.includes(COOKIE), false)
  assert.equal(stdin, COOKIE)
  console.log("COOKIE_IN_ARGV no")
  console.log("COOKIE_ON_STDIN yes")
  console.log(`CONNECTED ip=${state.ip} gateway=${state.gateway} expires=${state.expires}`)

  const gone = await run(gpvpn, ["disconnect"], home.env)
  assert.equal(gone.code, 0, gone.stderr + gone.stdout)
  assert.equal(JSON.parse(gone.stdout).state, "idle")
  console.log("IDLE after disconnect")

  const later = await run(gpvpn, ["status"], home.env)
  assert.equal(later.code, 0, later.stderr + later.stdout)
  assert.equal(later.stdout.includes(COOKIE), false)
  const status = JSON.parse(later.stdout)
  assert.equal(status.state, "idle")
  assert.equal(daemon.child.exitCode, null)
  process.kill(pid, 0)
  console.log(`STATUS_AFTER idle pid=${pid}`)
  console.log("DAEMON_STILL_UP yes")
  console.log(`SOCKET ${daemon.sock}`)

  // ---- password mode flow -----------------------------------------------
  // Create a fake SAML script that exits cleanly (won't be called in pw mode)
  const samlScript = path.join(home.env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  await writeFile(samlScript, `
import sys
sys.exit(0)
`)

  // Create a password-mode profile with options
  const pwProfile = "PwTest"
  const pwEnv = { ...home.env, GPVPN_SOCKET: daemon.sock }
  const addPw = await run(gpvpn, [
    "profile", "add", "--name", pwProfile,
    "--portal", "vpn.example.com", "--username", "user@example.com",
  ], pwEnv)
  assert.equal(addPw.code, 0, addPw.stderr)

  // Set authMethod=password and options
  await run(gpvpn, ["profile", "set", pwProfile, "authMethod", "password"], pwEnv)
  await run(gpvpn, ["profile", "set", pwProfile, "os", "win"], pwEnv)
  await run(gpvpn, ["profile", "set", pwProfile, "noDtls", "On"], pwEnv)

  // Connect with password via stdin
  const pwResult = await run(gpvpn, ["connect", "--profile", pwProfile], pwEnv, "testpassword123\n")
  assert.equal(pwResult.code, 0, pwResult.stderr + pwResult.stdout)
  const pwState = JSON.parse(pwResult.stdout)
  assert.equal(pwState.state, "connected")

  // Verify: argv contains --os win --no-dtls but NOT the password
  const pwArgv = await readText(path.join(daemon.ocDir, "argv"))
  assert.ok(pwArgv.includes("--os"), `expected --os in argv: ${pwArgv}`)
  assert.ok(pwArgv.includes("win"), `expected win in argv: ${pwArgv}`)
  assert.ok(pwArgv.includes("--no-dtls"), `expected --no-dtls in argv: ${pwArgv}`)
  assert.equal(pwArgv.includes("testpassword123"), false, "password must NOT be in argv")

  // Password IS on stdin
  const pwStdin = (await readText(path.join(daemon.ocDir, "stdin"))).trim()
  assert.equal(pwStdin, "testpassword123", "password must be on stdin")

  console.log("PASSWORD_MODE yes")
  console.log(`CONNECTED ip=${pwState.ip} gateway=${pwState.gateway}`)

  // Cleanup
  await run(gpvpn, ["disconnect"], pwEnv)
  console.log("IDLE after disconnect")

  // Forget test
  const digest = crypto.createHash("sha256").update(pwProfile).digest("hex").slice(0, 8)
  const cacheDir = path.join(home.env.XDG_CACHE_HOME, "gp-vpn")
  await mkdir(cacheDir, { recursive: true })
  const jarPath = path.join(cacheDir, `okta-${digest}.json`)
  await writeFile(jarPath, "{}")
  const forget = await run(gpvpn, ["forget", pwProfile], pwEnv)
  assert.equal(forget.code, 0)
  const forgetJson = JSON.parse(forget.stdout)
  assert.equal(forgetJson.forgot, pwProfile)
  // Idempotent: forget again
  const forget2 = await run(gpvpn, ["forget", pwProfile], pwEnv)
  assert.equal(forget2.code, 0)
  console.log("FORGET idempotent")

  console.log("ALL TESTS PASSED")
} finally {
  await stopDaemon(daemon.child)
}
