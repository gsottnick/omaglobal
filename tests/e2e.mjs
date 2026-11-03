import assert from "node:assert/strict"
import { mkdir } from "node:fs/promises"
import path from "node:path"
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
} finally {
  await stopDaemon(daemon.child)
}
