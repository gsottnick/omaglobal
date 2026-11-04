import test from "node:test"
import assert from "node:assert/strict"
import { readFile, mkdir, writeFile, chmod, mkdtemp } from "node:fs/promises"
import { spawn, spawnSync } from "node:child_process"
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

// ── setup.sh integration tests ──────────────────────────────────────────────

function fakeBin(body) {
  return `#!/usr/bin/env bash\n${body}\n`
}

async function setupFakeEnv(tmpDir) {
  const binDir = path.join(tmpDir, "fakes")
  await mkdir(binDir, { recursive: true })

  // fake sudo: just exec remaining args
  await writeFile(path.join(binDir, "sudo"), fakeBin('exec "$@"'))
  await chmod(path.join(binDir, "sudo"), 0o755)

  // fake pacman: record args, exit 0 (or configurable via EXIT_CODE env var)
  await writeFile(path.join(binDir, "pacman"),
    '#!/usr/bin/env bash\necho "PACMAN: $*" >> /tmp/fake-pacman.log\nexit "${EXIT_CODE:-0}"\n')
  await chmod(path.join(binDir, "pacman"), 0o755)

  // fake systemctl: is-active → active; others → success
  await writeFile(path.join(binDir, "systemctl"),
    '#!/usr/bin/env bash\necho "SYSTEMCTL: $*" >> /tmp/fake-systemctl.log\nif [[ "$1" == "is-active" ]]; then echo "active"; fi\nexit 0\n')
  await chmod(path.join(binDir, "systemctl"), 0o755)

  // fake git: exec real git (tests override GP_SAML_GIT_URL for clone source)
  await writeFile(path.join(binDir, "git"),
    '#!/usr/bin/env bash\nexec /usr/bin/git "$@"\n')
  await chmod(path.join(binDir, "git"), 0o755)

  // fake install: just succeed (used for system-wide installs)
  await writeFile(path.join(binDir, "install"),
    '#!/usr/bin/env bash\n# no-op install for tests\necho "INSTALL: $*" >> /tmp/fake-install.log\nexit 0\n')
  await chmod(path.join(binDir, "install"), 0o755)

  // fake gpvpn: setup-check always succeeds
  const gpvpnReal = gpvpn
  await writeFile(path.join(binDir, "gpvpn"),
    "#!/usr/bin/env bash\nif [[ \"${1:-}\" == \"setup-check\" ]]; then exit 0; fi\nexec /usr/bin/python3 " + gpvpnReal + ' "$@"\n')
  await chmod(path.join(binDir, "gpvpn"), 0o755)

  return { env: { ...process.env, PATH: binDir + ":" + process.env.PATH } }
}

function readStatus(stateDir) {
  return readFile(path.join(stateDir, "gp-vpn", "install.json"), "utf8")
}

async function makeGitFixture(tmpDir) {
  const repoPath = path.join(tmpDir, "fixture-repo")
  await mkdir(repoPath, { recursive: true })
  spawnSync("/usr/bin/git", ["init"], { cwd: repoPath, stdio: "pipe" })
  spawnSync("/usr/bin/git", ["config", "user.email", "fixture@local"], { cwd: repoPath, stdio: "pipe" })
  spawnSync("/usr/bin/git", ["config", "user.name", "Test"], { cwd: repoPath, stdio: "pipe" })
  await writeFile(path.join(repoPath, "README.md"), "# gp-saml-gui")
  spawnSync("/usr/bin/git", ["add", "."], { cwd: repoPath, stdio: "pipe" })
  spawnSync("/usr/bin/git", ["commit", "-m", "initial"], { cwd: repoPath, stdio: "pipe" })
  // Return the actual commit hash so the test can set GP_SAML_GIT_PIN
  const { stdout } = spawnSync("/usr/bin/git", ["rev-parse", "HEAD"], { cwd: repoPath, stdio: "pipe" })
  return { path: repoPath, pin: stdout.toString().trim() }
}

function runScript(scriptPath, env, args = []) {
  return new Promise((resolve, reject) => {
    const child = spawn("bash", [scriptPath, ...args], { env, stdio: ["pipe", "pipe", "pipe"] })
    let stdout = "", stderr = ""
    child.stdout.on("data", (c) => { stdout += c })
    child.stderr.on("data", (c) => { stderr += c })
    child.on("error", reject)
    child.on("close", (code) => resolve({ code, stdout, stderr }))
  })
}

test("setup.sh happy path ends with done", async () => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "omaglobal-setup-"))
  const stateDir = path.join(tmpDir, "state")
  const dataDir = path.join(tmpDir, "data")
  const configDir = path.join(tmpDir, "config")
  await mkdir(path.join(dataDir, "gp-vpn", "gp-saml-gui"), { recursive: true })
  await mkdir(stateDir, { recursive: true })
  await mkdir(configDir, { recursive: true })

  const fakeEnv = await setupFakeEnv(tmpDir)
  const fixture = await makeGitFixture(tmpDir)
  const gitRepo = fixture.path

  const env = {
    ...fakeEnv.env,
    HOME: tmpDir,
    XDG_STATE_HOME: stateDir,
    XDG_DATA_HOME: dataDir,
    XDG_CONFIG_HOME: configDir,
    GP_SAML_GIT_URL: gitRepo,
    GP_SAML_GIT_PIN: fixture.pin,
  }

  const scriptPath = path.join(repo, "tools/setup.sh")
  const result = await runScript(scriptPath, env)
  assert.equal(result.code, 0, `exit code: ${result.code}\nstderr: ${result.stderr}`)
  assert.ok(result.stdout.includes("Step 1 of 4"))
  assert.ok(result.stdout.includes("close this terminal"))

  const status = JSON.parse(await readStatus(stateDir))
  assert.equal(status.status, "done")
  assert.equal(status.step, "done")
  console.log("happy path done")
})

test("setup.sh is idempotent", async () => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "omaglobal-idem-"))
  const stateDir = path.join(tmpDir, "state")
  const dataDir = path.join(tmpDir, "data")
  const configDir = path.join(tmpDir, "config")
  await mkdir(path.join(dataDir, "gp-vpn", "gp-saml-gui"), { recursive: true })
  await mkdir(stateDir, { recursive: true })
  await mkdir(configDir, { recursive: true })

  const fakeEnv = await setupFakeEnv(tmpDir)
  const fixture = await makeGitFixture(tmpDir)

  const env = {
    ...fakeEnv.env,
    HOME: tmpDir,
    XDG_STATE_HOME: stateDir,
    XDG_DATA_HOME: dataDir,
    XDG_CONFIG_HOME: configDir,
    GP_SAML_GIT_URL: fixture.path,
    GP_SAML_GIT_PIN: fixture.pin,
  }

  const scriptPath = path.join(repo, "tools/setup.sh")
  const r1 = await runScript(scriptPath, env)
  assert.equal(r1.code, 0, r1.stderr)
  const r2 = await runScript(scriptPath, env)
  assert.equal(r2.code, 0, r2.stderr)
  const status = JSON.parse(await readStatus(stateDir))
  assert.equal(status.status, "done")
  console.log("idempotent done")
})

test("setup.sh package failure writes failed json", async () => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "omaglobal-pkgfail-"))
  const stateDir = path.join(tmpDir, "state")
  await mkdir(stateDir, { recursive: true })

  const fakeEnv = await setupFakeEnv(tmpDir)
  const env = { ...fakeEnv.env, HOME: tmpDir, XDG_STATE_HOME: stateDir, EXIT_CODE: "1" }
  const scriptPath = path.join(repo, "tools/setup.sh")
  const result = await runScript(scriptPath, env)
  assert.notEqual(result.code, 0)

  const status = JSON.parse(await readStatus(stateDir))
  assert.equal(status.status, "failed")
  assert.equal(status.step, "packages")
  assert.ok(status.error.length > 0)
  // No shell internals in the error
  assert.doesNotMatch(status.error, /\bexit\b/)
  assert.doesNotMatch(status.error, /pipefail|trap|ERR/)
  console.log("package failure done")
})

test("setup.sh verify failure writes failed json", async () => {
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "omaglobal-verifyfail-"))
  const stateDir = path.join(tmpDir, "state")
  const dataDir = path.join(tmpDir, "data")
  const configDir = path.join(tmpDir, "config")
  await mkdir(path.join(dataDir, "gp-vpn", "gp-saml-gui"), { recursive: true })
  await mkdir(stateDir, { recursive: true })
  await mkdir(configDir, { recursive: true })

  const fakeEnv = await setupFakeEnv(tmpDir)
  const fixture = await makeGitFixture(tmpDir)
  // Override systemctl to report inactive for is-active
  const binDir = path.join(tmpDir, "fakes")
  await writeFile(path.join(binDir, "systemctl"),
    '#!/usr/bin/env bash\necho "SYSTEMCTL: $*" >> /tmp/fake-systemctl.log\nif [[ "$1" == "is-active" ]]; then echo "inactive"; exit 1; fi\nexit 0\n')

  const env = {
    ...fakeEnv.env,
    HOME: tmpDir,
    XDG_STATE_HOME: stateDir,
    XDG_DATA_HOME: dataDir,
    XDG_CONFIG_HOME: configDir,
    GP_SAML_GIT_URL: fixture.path,
    GP_SAML_GIT_PIN: fixture.pin,
  }
  const scriptPath = path.join(repo, "tools/setup.sh")
  const result = await runScript(scriptPath, env)
  assert.notEqual(result.code, 0)

  const status = JSON.parse(await readStatus(stateDir))
  assert.equal(status.status, "failed")
  assert.equal(status.step, "verify")
  console.log("verify failure done")
})

test("setup.sh -h prints usage line", async () => {
  const scriptPath = path.join(repo, "tools/setup.sh")
  const result = await runScript(scriptPath, process.env, ["-h"])
  assert.equal(result.code, 0)
  assert.equal(result.stdout.trim(), "tools/setup.sh")
  console.log("help flag done")
})
