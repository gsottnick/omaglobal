// The stand-ins in these tests print what the real tools print. Failure text was
// captured from gp-saml-gui at the pinned commit and from openconnect 9.21.
import test from "node:test"
import assert from "node:assert/strict"
import { spawn, spawnSync } from "node:child_process"
import { readFile, writeFile, mkdir } from "node:fs/promises"
import path from "node:path"
import { COOKIE, SAML_OK, SAML_PORTAL, gpvpn, gpvpnd, tempHome, run, startDaemon, stopDaemon, waitForDaemon, writeSaml } from "./support.mjs"

// Load a function from a shipped script, not a copy of it.
const python = (file, body) => {
  const result = spawnSync("python3", ["-c", `
import importlib.machinery, importlib.util, json, sys
loader = importlib.machinery.SourceFileLoader("shipped", sys.argv[1])
spec = importlib.util.spec_from_loader("shipped", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
${body}
`, file], { encoding: "utf8", timeout: 5000, input: "" })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trim()
}

test("the server comes from the openconnect line, not the next heading", () => {
  const parsed = JSON.parse(python(gpvpn, `print(json.dumps(mod.parse_saml(sys.stdin.read() or ${JSON.stringify(SAML_PORTAL)})))`))
  assert.deepEqual(parsed, { cookie: COOKIE, user: "user@example.com", usergroup: "portal:prelogin-cookie", server: "vpn.example.com" })
})

test("sign-in failures say what happened", () => {
  const cases = [
    ["Login window closed by user.", /cancelled/],
    ["requests.exceptions.ConnectionError: HTTPSConnectionPool(host='nonexistent.invalid', port=443): Max retries exceeded with url: /global-protect/prelogin.esp (Caused by NameResolutionError(\"Failed to resolve 'nonexistent.invalid' ([Errno -2] Name or service not known)\"))", /Could not find that VPN address/],
    ["xml.etree.ElementTree.ParseError: syntax error: line 1, column 0", /did not answer like a GlobalProtect VPN/],
    ["SSL certificate error (try --no-verify to ignore): certificate verify failed", /certificate could not be checked/],
    ["Portal prelogin response does not contain SAML tags (<saml-auth-method> or <saml-request> missing)", /choose Password/],
    ["requests.exceptions.ConnectionError: HTTPSConnectionPool(host='vpn.example.com', port=443): Max retries exceeded with url: / (Caused by ConnectTimeoutError(...timed out))", /Could not reach the VPN/],
  ]
  for (const [text, expected] of cases) {
    assert.match(python(gpvpn, `print(mod.saml_failure(${JSON.stringify(text)}))`), expected)
  }
})

test("openconnect's real progress reads as healthy, and its failures keep their cause", () => {
  const healthy = ["Connected to HTTPS on vpn.example.com with ciphersuite (TLS1.3)-(AES-256-GCM)", "Gateway says no HIP report submission is needed.", "Session authentication will expire at Tue, 01 Jan 2030 00:00:00 UTC"]
  for (const line of healthy) assert.equal(python(gpvpnd, `print(mod.map_failure(${JSON.stringify(line)}))`), "None")
  const explain = (lines) => python(gpvpnd, `print(mod.explain_failure(${JSON.stringify(lines)}))`)
  assert.match(explain(["getaddrinfo failed for host 'nonexistent.invalid': Name or service not known", "Failed to open HTTPS connection to nonexistent.invalid", "Failed to complete authentication"]), /Could not find that VPN address/)
  assert.match(explain(["Login failed.", "Failed to complete authentication"]), /refused the sign-in/)
  assert.match(explain(["Failed to complete authentication"]), /Check the portal address/)
  assert.equal(python(gpvpnd, `print(mod.expiry_iso("Tue, 01 Jan 2030 00:00:00 UTC"))`), "2030-01-01T00:00:00")
})

test("a portal with several gateways connects to the best one", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_PORTAL)
  const daemon = startDaemon(dir, env, "need-authgroup")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Work"], env)
    assert.equal(result.code, 0, result.stderr)
    const state = JSON.parse(result.stdout)
    assert.equal(state.state, "connected")
    assert.equal(state.gateway, "PROD-EXAMPLE")
    assert.equal(state.ip, "172.16.8.8")
    const argv = (await readFile(path.join(dir, "oc", "argv"), "utf8")).split("\n")
    assert.ok(argv.includes("--authgroup=PROD-EXAMPLE"))
    assert.equal(argv.filter(Boolean).at(-1), "vpn.example.com")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a picked gateway goes through the portal with --authgroup", async () => {
  const { dir, env } = await tempHome()
  await writeSaml(env, SAML_PORTAL)
  const daemon = startDaemon(dir, env, "need-authgroup")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com", "--gateway", "backup.example.com", "--gateway-name", "BACKUP-EXAMPLE"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Work"], env)
    assert.equal(result.code, 0, result.stderr)
    const argv = (await readFile(path.join(dir, "oc", "argv"), "utf8")).split("\n")
    assert.ok(argv.includes("--authgroup=BACKUP-EXAMPLE"))
    assert.equal(argv.filter(Boolean).at(-1), "vpn.example.com")
    assert.equal(JSON.parse(result.stdout).gateway, "BACKUP-EXAMPLE")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a missing portal interface falls back to the gateway sign-in", async () => {
  const { dir, env } = await tempHome()
  const script = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  await mkdir(path.dirname(script), { recursive: true })
  await writeFile(script, `import sys
if "-p" in sys.argv:
    sys.stderr.write("Portal interface does not exist; specify --gateway instead\\n")
    sys.exit(2)
sys.stderr.write(${JSON.stringify(SAML_OK)})
`)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Work"], env)
    assert.equal(result.code, 0, result.stderr)
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("the sign-in reports the same system and certificates as the tunnel", async () => {
  const { env } = await tempHome()
  const ca = path.join(env.HOME, "ca.pem")
  await writeFile(ca, "ca")
  const out = python(gpvpn, `
env, argv = mod.saml_env_and_argv("vpn.example.com", "/j", "portal", {"os": "win", "useragent": "PAN GlobalProtect", "certificate": "/c.pem", "sslkey": "/k.pem", "cafile": ${JSON.stringify(ca)}})
print(json.dumps({"argv": argv[2:], "ca": env.get("REQUESTS_CA_BUNDLE")}))`)
  const { argv, ca: bundle } = JSON.parse(out)
  assert.deepEqual(argv, ["-p", "--clientos", "Windows", "-C", "/j", "--user-agent", "PAN GlobalProtect", "--cert", "/c.pem", "--key", "/k.pem", "vpn.example.com"])
  assert.equal(bundle, ca)
})

test("an edit made during sign-in survives the connect", async () => {
  const { dir, env } = await tempHome()
  const script = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  await mkdir(path.dirname(script), { recursive: true })
  await writeFile(script, `import subprocess, sys
subprocess.run([${JSON.stringify(gpvpn)}, "profile", "set", "Work", "username", "user@example.com"], check=True, capture_output=True)
sys.stderr.write(${JSON.stringify(SAML_PORTAL)})
`)
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"], env)
    assert.equal((await run(gpvpn, ["connect", "--profile", "Work"], env)).code, 0)
    const store = JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
    assert.equal(store.profiles[0].username, "user@example.com")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("stopping the helper closes the sign-in window", async () => {
  const { env } = await tempHome()
  const script = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  const pidFile = path.join(env.HOME, "saml.pid")
  await mkdir(path.dirname(script), { recursive: true })
  await writeFile(script, `import os, time
open(${JSON.stringify(pidFile)}, "w").write(str(os.getpid()))
time.sleep(60)
`)
  await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com"], env)
  const child = spawn(gpvpn, ["connect", "--profile", "Work"], { env, stdio: "ignore" })
  let pid = ""
  for (let i = 0; i < 100 && !pid; i++) {
    await new Promise((resolve) => setTimeout(resolve, 30))
    pid = await readFile(pidFile, "utf8").catch(() => "")
  }
  assert.ok(pid)
  child.kill("SIGTERM")
  await new Promise((resolve) => child.on("exit", resolve))
  await new Promise((resolve) => setTimeout(resolve, 100))
  const alive = spawnSync("kill", ["-0", pid]).status === 0
  assert.equal(alive, false)
})

test("a password reaches openconnect exactly, however it starts", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "ok")
  try {
    env.GPVPN_SOCKET = daemon.sock
    await waitForDaemon(daemon.sock)
    await run(gpvpn, ["profile", "add", "--name", "Work", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
    await run(gpvpn, ["profile", "set", "Work", "authMethod", "password"], env)
    const result = await run(gpvpn, ["connect", "--profile", "Work"], env, "-a pass word\n")
    assert.equal(result.code, 0, result.stderr)
    assert.equal(await readFile(path.join(dir, "oc", "stdin"), "utf8"), "-a pass word\n")
    const argv = await readFile(path.join(dir, "oc", "argv"), "utf8")
    assert.equal(argv.includes("pass word"), false)
  } finally {
    await stopDaemon(daemon.child)
  }
})
