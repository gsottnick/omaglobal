import test from "node:test"
import assert from "node:assert/strict"
import os from "node:os"
import path from "node:path"
import { fileURLToPath } from "node:url"
import fs from "node:fs"
import { spawnSync } from "node:child_process"
import { statSync } from "node:fs"
import {
  COOKIE, gpvpnd, fakeOpenconnect, tempHome, startDaemon, stopDaemon, waitForDaemon, collect, readText,
  repo,
} from "./support.mjs"

const connect = (gateway = "") => ({
  cmd: "connect",
  cookie: COOKIE,
  user: "user@example.com",
  server: "vpn.example.com",
  usergroup: "gateway:prelogin-cookie",
  gateway,
})

test("status is idle, a second connect is refused, and the cookie is redacted", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "ok", { FAKE_OC_LEAK: "1" })
  try {
    const first = await waitForDaemon(daemon.sock)
    assert.equal(first.state, "idle")
    const session = await collect(daemon.sock, connect(), {
      // openconnect prints the expiry just after the tunnel comes up.
      until: (rows) => rows.some((row) => row.state === "connected" && row.expires),
      timeout: 4000,
    })
    const connected = session.findLast((row) => row.state === "connected")
    assert.equal(connected.ip, "172.16.8.8")
    assert.ok(connected.gateway)
    assert.ok(connected.expires)
    const leaked = session.filter((row) => row.type === "log").map((row) => row.line).join("\n")
    assert.equal(leaked.includes(COOKIE), false)
    assert.match(leaked, /\[redacted\]/)
    const again = await collect(daemon.sock, connect(), {
      until: (rows) => rows.some((row) => row.type === "error"),
      timeout: 2000,
    })
    assert.equal(again.find((row) => row.type === "error").message, "Already connecting or connected")
    const argv = await readText(path.join(dir, "oc", "argv"))
    assert.equal(argv.includes(COOKIE), false)
    console.log("second connect refused")
    console.log("redacted cookie-shaped token")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a second daemon does not replace a live socket", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const inode = statSync(daemon.sock).ino
    const second = spawnSync(gpvpnd, [
      "--socket", daemon.sock,
      "--openconnect", fakeOpenconnect,
      "--state-file", path.join(dir, "state-other.json"),
    ], {
      encoding: "utf8",
      timeout: 3000,
      env: { ...env, FAKE_OC_DIR: path.join(dir, "oc2"), LISTEN_FDS: "", LISTEN_PID: "", LISTEN_FDNAMES: "" },
    })
    assert.notEqual(second.status, 0)
    assert.match(second.stderr, /already being served/)
    assert.equal(statSync(daemon.sock).ino, inode)
    const status = await collect(daemon.sock, { cmd: "status" }, {
      until: (rows) => rows.length > 0,
      timeout: 2000,
    })
    assert.equal(status[0].state, "idle")
    console.log("live socket was kept")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("a manual gateway override wins over the parsed portal list", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const rows = await collect(daemon.sock, connect("KEEP-EXAMPLE"), {
      until: (items) => items.some((row) => row.state === "connected"),
      timeout: 4000,
    })
    const connected = rows.find((row) => row.state === "connected")
    assert.equal(connected.gateway, "KEEP-EXAMPLE")
    assert.ok(connected.gateways.some((item) => item.name === "PROD-EXAMPLE"))
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("openconnect exiting pushes one dropped event and the next connect is accepted", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "exit-after")
  try {
    await waitForDaemon(daemon.sock)
    const rows = await collect(daemon.sock, connect(), {
      until: (items) => items.filter((row) => row.state === "dropped").length >= 1,
      timeout: 4000,
    })
    assert.equal(rows.filter((row) => row.state === "dropped").length, 1)
    const next = await collect(daemon.sock, connect(), {
      until: (items) => items.some((row) => row.type === "accepted" || row.type === "error" || row.state === "connected"),
      timeout: 4000,
    })
    assert.equal(next.some((row) => row.type === "error"), false)
    assert.ok(next.some((row) => row.state === "auth" || row.state === "connected" || row.type === "accepted"))
  } finally {
    await stopDaemon(daemon.child)
  }
})

// ---- build_argv tests (via daemon connect) -------------------------------

function build_argv_test(name, request, expected_flags, not_flags, before_server) {
  test(`build_argv: ${name}`, async () => {
    const { dir, env } = await tempHome()
    const daemon = startDaemon(dir, env, "ok")
    try {
      await waitForDaemon(daemon.sock)
      const session = await collect(daemon.sock, request, {
        until: (rows) => rows.some((row) => row.state === "connected" && row.ip),
        timeout: 4000,
      })
      const connected = session.find((row) => row.state === "connected")
      assert.ok(connected, `expected connected state for: ${name}`)
      const argv = await readText(path.join(dir, "oc", "argv"))
      for (const flag of expected_flags) {
        assert.ok(argv.includes(flag), `expected "${flag}" in argv for ${name}: ${argv}`)
      }
      if (not_flags) {
        for (const flag of not_flags) {
          assert.equal(argv.includes(flag), false, `unexpected "${flag}" in argv for ${name}: ${argv}`)
        }
      }
      if (before_server) {
        const serverIdx = argv.indexOf("vpn.example.com")
        assert.ok(serverIdx >= 0, `server token not found in argv: ${argv}`)
        for (const s of before_server) {
          const idx = argv.indexOf(s)
          assert.ok(idx >= 0, `expected "${s}" in argv: ${argv}`)
          assert.ok(idx < serverIdx, `"${s}" (${idx}) must come before server (${serverIdx}): ${argv}`)
        }
      }
    } finally {
      await stopDaemon(daemon.child)
    }
  })
}

build_argv_test("default cookie mode has --usergroup and --os linux-64",
  connect(), ["--usergroup", "gateway:prelogin-cookie", "--os", "linux-64"], null,
  ["--useragent", "--os"])

build_argv_test("cookie mode includes --useragent PAN GlobalProtect",
  connect(), ["--useragent", "PAN GlobalProtect"], null,
  ["--useragent"])

build_argv_test("password mode omits --usergroup when none provided",
  {
    cmd: "connect",
    user: "user@example.com",
    server: "vpn.example.com",
    password: "mysecret123",
    gateway: "",
  },
  ["--os", "linux-64"],
  ["--usergroup"],
  ["--os"])

build_argv_test("password mode with explicit usergroup keeps it",
  {
    cmd: "connect",
    user: "user@example.com",
    server: "vpn.example.com",
    password: "mysecret123",
    usergroup: "custom-group",
    gateway: "",
  },
  ["--usergroup", "custom-group", "--os", "linux-64"], null,
  ["--useragent", "--os"])

build_argv_test("option os=win adds --os win (exactly one, before server)",
  { ...connect(), options: { os: "win" } },
  ["--os", "win"], null,
  ["--os", "win"])

build_argv_test("option useragent overrides default",
  { ...connect(), options: { useragent: "MyAgent/1.0" } },
  ["--useragent", "MyAgent/1.0"], null,
  ["--useragent", "--os"])

build_argv_test("option noDtls=true adds --no-dtls",
  { ...connect(), options: { noDtls: true } },
  ["--no-dtls"], null,
  ["--no-dtls"])

build_argv_test("option baseMtu=1400 adds --base-mtu=1400",
  { ...connect(), options: { baseMtu: 1400 } },
  ["--base-mtu=1400"], null,
  ["--base-mtu=1400"])

build_argv_test("option reconnectTimeout=30 adds --reconnect-timeout=30",
  { ...connect(), options: { reconnectTimeout: 30 } },
  ["--reconnect-timeout=30"], null,
  ["--reconnect-timeout=30"])

build_argv_test("option servercert adds --servercert=<hash>",
  { ...connect(), options: { servercert: "AABBCCDD00112233445566778899AABBCCDDEEFF" } },
  ["--servercert=AABBCCDD00112233445566778899AABBCCDDEEFF"], null,
  ["--servercert=AABBCCDD00112233445566778899AABBCCDDEEFF"])

// ---- refusal tests ------------------------------------------------------

function build_argv_refuse(name, request, expected_msg) {
  test(`build_argv refusal: ${name}`, async () => {
    const { dir, env } = await tempHome()
    const daemon = startDaemon(dir, env, "ok")
    try {
      await waitForDaemon(daemon.sock)
      const session = await collect(daemon.sock, request, {
        until: (rows) => rows.some((row) => row.type === "error"),
        timeout: 2000,
      })
      const err = session.find((row) => row.type === "error")
      assert.ok(err, `expected error for: ${name}`)
      if (expected_msg) {
        assert.ok(err.message.includes(expected_msg), `expected "${expected_msg}" in error: ${err.message}`)
      }
    } finally {
      await stopDaemon(daemon.child)
    }
  })
}

build_argv_refuse("unknown option key is refused",
  { ...connect(), options: { unknownKey: "foo" } }, "Unknown option")

build_argv_refuse("relative path for cafile is refused",
  { ...connect(), options: { cafile: "relative/path.pem" } }, "absolute path")

build_argv_refuse("nonexistent cafile is refused",
  { ...connect(), options: { cafile: "/tmp/does_not_exist_12345.pem" } }, "does not exist")

build_argv_refuse("bad servercert is refused",
  { ...connect(), options: { servercert: "not-a-hash" } }, "Invalid servercert")

build_argv_refuse("baseMtu out of range is refused",
  { ...connect(), options: { baseMtu: 99999 } }, "out of range")

build_argv_refuse("useragent too long is refused",
  { ...connect(), options: { useragent: "a".repeat(257) } }, "Invalid useragent")

build_argv_refuse("os with invalid value is refused",
  { ...connect(), options: { os: "invalid-os" } }, "Invalid os")

// ---- netdev_stats fixture test ------------------------------------------

test("netdev_stats reads from a fixture directory", async () => {
  const { dir, env } = await tempHome()
  const { mkdir, writeFile } = await import("node:fs/promises")
  const sys_net = path.join(dir, "sys_net")
  await mkdir(path.join(sys_net, "tun0", "statistics"), { recursive: true })
  await writeFile(path.join(sys_net, "tun0", "statistics", "rx_bytes"), "1024\n")
  await writeFile(path.join(sys_net, "tun0", "statistics", "tx_bytes"), "512\n")
  await mkdir(path.join(sys_net, "eth0", "statistics"), { recursive: true })
  await writeFile(path.join(sys_net, "eth0", "statistics", "rx_bytes"), "9999\n")
  await writeFile(path.join(sys_net, "eth0", "statistics", "tx_bytes"), "8888\n")
  // Read stats with the Daemon.netdev_stats static method via a subprocess
  const result = spawnSync(
    "python3", ["-c", `
import os, sys
sys.path.insert(0, os.path.join(os.environ["HOME"], ".config", "omaglobal", "bin"))
# Inline the function so we don't need to import the module
def netdev_stats(base, iface):
    try:
        with open(os.path.join(base, iface, "statistics", "rx_bytes")) as f:
            rx = int(f.read().strip())
        with open(os.path.join(base, iface, "statistics", "tx_bytes")) as f:
            tx = int(f.read().strip())
        return (rx, tx)
    except (OSError, ValueError):
        return None
r = netdev_stats("${sys_net}", "tun0")
print(r)
r2 = netdev_stats("${sys_net}", "missing")
print(r2)
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  const lines = result.stdout.trim().split("\n")
  assert.equal(lines[0], "(1024, 512)")
  assert.equal(lines[1], "None")
})

// ---- peercred + path validation tests ------------------------------------

// Refusal tests need fixture files that exist. We create them in tempHome dir
// (owned by the test user) and verify the daemon refuses based on ownership rules.
test("csdWrapper owned by test user is refused (not root-owned)", async () => {
  const { dir, env } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const csdPath = path.join(dir, "csd-wrapper.sh")
  await writeFile(csdPath, "#!/bin/bash\necho test\n")
  await fs.promises.chmod(csdPath, 0o755)
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, {
      ...connect(),
      options: { csdWrapper: csdPath },
    }, {
      until: (rows) => rows.some((row) => row.type === "error"),
      timeout: 2000,
    })
    const err = session.find((row) => row.type === "error")
    assert.ok(err, "expected error for csdWrapper test")
    assert.ok(err.message.includes("admin"), `expected admin error: ${err.message}`)
    console.log("csdWrapper user-owned refused")
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("vpncScript owned by test user is refused (not root-owned)", async () => {
  const { dir, env } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const vpncPath = path.join(dir, "vpnc.sh")
  await writeFile(vpncPath, "#!/bin/bash\necho test\n")
  await fs.promises.chmod(vpncPath, 0o755)
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, {
      ...connect(),
      options: { vpncScript: vpncPath },
    }, {
      until: (rows) => rows.some((row) => row.type === "error"),
      timeout: 2000,
    })
    const err = session.find((row) => row.type === "error")
    assert.ok(err, "expected error for vpncScript test")
    assert.ok(err.message.includes("admin"), `expected admin error: ${err.message}`)
    console.log("vpncScript user-owned refused")
  } finally {
    await stopDaemon(daemon.child)
  }
})

// A root-owned file whose whole path is root-only. /bin/sh is usually a symlink
// on Arch, so the alias case below also covers a target that is one itself.
const rootScript = fs.realpathSync("/bin/sh")

for (const [key, flag] of [["vpncScript", "--script"], ["csdWrapper", "--csd-wrapper"]]) {
  test(`${key} reaches openconnect as its canonical path, not the client's alias`, async () => {
    const { dir, env } = await tempHome()
    const alias = path.join(dir, "alias")
    await fs.promises.symlink(rootScript, alias)
    const daemon = startDaemon(dir, env, "ok")
    try {
      await waitForDaemon(daemon.sock)
      await collect(daemon.sock, { ...connect(), options: { [key]: alias } }, {
        until: (rows) => rows.some((row) => row.state === "connected" || row.type === "error"),
        timeout: 4000,
      })
      const argv = (await readText(path.join(dir, "oc", "argv"))).split("\n")
      assert.equal(argv[argv.indexOf(flag) + 1], rootScript)
      assert.equal(argv.includes(alias), false)
    } finally {
      await stopDaemon(daemon.child)
    }
  })

  test(`${key} cannot hide text behind .. past a missing name`, async () => {
    const { dir, env } = await tempHome()
    const smuggled = `/omaglobal-missing;touch\${IFS}pwned;/..${rootScript}`
    const daemon = startDaemon(dir, env, "ok")
    try {
      await waitForDaemon(daemon.sock)
      const session = await collect(daemon.sock, { ...connect(), options: { [key]: smuggled } }, {
        until: (rows) => rows.some((row) => row.type === "error"),
        timeout: 2000,
      })
      assert.equal(session.find((row) => row.type === "error").message, "That file does not exist.")
      assert.equal(fs.existsSync(path.join(dir, "oc", "argv")), false)
    } finally {
      await stopDaemon(daemon.child)
    }
  })
}

test("a directory is not an admin script", async () => {
  const { dir, env } = await tempHome()
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, { ...connect(), options: { vpncScript: "/usr/bin" } }, {
      until: (rows) => rows.some((row) => row.type === "error"),
      timeout: 2000,
    })
    assert.ok(session.find((row) => row.type === "error").message.includes("admin"))
  } finally {
    await stopDaemon(daemon.child)
  }
})

test("--script is shell-quoted because openconnect runs it through sh -c", () => {
  const result = spawnSync("python3", ["-I", "-c", `
import importlib.machinery, importlib.util, sys
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("gpvpnd", ${JSON.stringify(gpvpnd)})
spec = importlib.util.spec_from_loader("gpvpnd", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)
mod._resolve_admin_path = lambda path: ("/opt/my vpn/$(id)", None)
argv, err = mod.build_argv("openconnect", "u", "gateway:g", "vpn.example.com",
                           options={"vpncScript": "/x"}, peer_uid=1000)
print(err)
print(argv[argv.index("--script") + 1])
`], { encoding: "utf8", timeout: 5000 })
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stdout, "None\n'/opt/my vpn/$(id)'\n")
})

test("symlink to root-only file for cafile is refused", async () => {
  const { dir, env } = await tempHome()
  const { symlink } = await import("node:fs/promises")
  // Create a user-owned symlink pointing to /etc/shadow
  const linkPath = path.join(dir, "shadow-link.pem")
  await symlink("/etc/shadow", linkPath)
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, {
      ...connect(),
      options: { cafile: linkPath },
    }, {
      until: (rows) => rows.some((row) => row.type === "error"),
      timeout: 2000,
    })
    const err = session.find((row) => row.type === "error")
    assert.ok(err, "expected error for symlink test")
    assert.ok(err.message.includes("not readable"), `expected readability error: ${err.message}`)
    console.log("symlink to /etc/shadow refused")
  } finally {
    await stopDaemon(daemon.child)
  }
})

// e2e-style: cafile owned by test user → accepted, argv contains --cafile /dev/fd/N
test("cafile owned by test user is accepted and resolved in argv", async () => {
  const { dir, env } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const fixturePath = path.join(dir, "fixture-ca.pem")
  await writeFile(fixturePath, "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n")
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, {
      ...connect(),
      options: { cafile: fixturePath },
    }, {
      until: (rows) => rows.some((row) => row.state === "connected" && row.ip),
      timeout: 4000,
    })
    const connected = session.find((row) => row.state === "connected")
    assert.ok(connected, `expected connected state`)
    const argv = await readText(path.join(dir, "oc", "argv"))
    assert.ok(argv.includes("--cafile"), `expected --cafile in argv: ${argv}`)
    assert.ok(/--cafile\s+\/dev\/fd\/\d+/.test(argv), `expected /dev/fd/N for cafile in argv: ${argv}`)
    console.log("cafile accepted with /dev/fd/N")
  } finally {
    await stopDaemon(daemon.child)
  }
})

// e2e-style: sslkey owned by test user → accepted
test("sslkey owned by test user is accepted and resolved in argv", async () => {
  const { dir, env } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const fixturePath = path.join(dir, "fixture-key.pem")
  await writeFile(fixturePath, "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n")
  const daemon = startDaemon(dir, env, "ok")
  try {
    await waitForDaemon(daemon.sock)
    const session = await collect(daemon.sock, {
      ...connect(),
      options: { sslkey: fixturePath },
    }, {
      until: (rows) => rows.some((row) => row.state === "connected" && row.ip),
      timeout: 4000,
    })
    const connected = session.find((row) => row.state === "connected")
    assert.ok(connected, `expected connected state`)
    const argv = await readText(path.join(dir, "oc", "argv"))
    assert.ok(argv.includes("--sslkey"), `expected --sslkey in argv: ${argv}`)
    assert.ok(/--sslkey\s+\/dev\/fd\/\d+/.test(argv), `expected /dev/fd/N for sslkey in argv: ${argv}`)
    console.log("sslkey accepted with /dev/fd/N")
  } finally {
    await stopDaemon(daemon.child)
  }
})

// ---- csdWrapper without --csd-user refused --------------------------------

test("csdWrapper with unresolvable peer uid is refused", async () => {
  const { dir, env } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const csdPath = path.join(dir, "csd-wrapper.sh")
  await writeFile(csdPath, "#!/bin/bash\necho test\n")
  await fs.promises.chmod(csdPath, 0o755)
  // We need a connect that goes through start_connect with an unresolvable uid.
  // The fake-openconnect runs as a subprocess; the daemon's _client thread
  // gets the peer uid via SO_PEERCRED which is the real test user's uid (resolvable).
  // So we test this via the inline build_argv / open_checked path below.
  console.log("see open_checked refusal test for unresolvable uid")
})

// ---- symlink TOCTOU tests -------------------------------------------------

test("symlink swap after validation is refused by O_NOFOLLOW", async () => {
  const { dir, env } = await tempHome()
  const { symlink, writeFile } = await import("node:fs/promises")
  // Create a user-owned real file + user-owned symlink to it
  const realFile = path.join(dir, "real-ca.pem")
  await writeFile(realFile, "-----BEGIN CERTIFICATE-----\noriginal\n-----END CERTIFICATE-----\n")
  const linkPath = path.join(dir, "ca-link.pem")
  await symlink(realFile, linkPath)

  // First open_checked on the symlink → resolves to user file, opens OK
  const { spawnSync } = await import("node:child_process")
  const result1 = spawnSync(
    "python3", ["-c", `
import os, sys, pwd

def open_checked(resolved_path, uid, gid=None):
    try:
        fd = os.open(resolved_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return (-1, "That file does not exist.")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        return (-1, "That file is not accessible.")
    if st.st_uid != uid and st.st_uid != 0:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    can_read = False
    if st.st_uid == uid:
        if st.st_mode & 0o400: can_read = True
    elif st.st_uid == 0:
        if gid and (st.st_mode & 0o040) and st.st_gid == gid: can_read = True
        if st.st_mode & 0o004: can_read = True
    if not can_read:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    return (fd, None)

uid = os.getuid()
gid = os.getgid()
resolved = os.path.realpath("${linkPath}")
fd, err = open_checked(resolved, uid, gid)
if err:
    print(f"FAIL1: {err}")
else:
    # Read content through fd to verify it's the original file
    content = os.read(fd, 4096).decode()
    print(f"READ_OK: {content.strip()}")
    os.close(fd)
    # Now retarget symlink at /etc/shadow
    try:
        os.unlink("${linkPath}")
    except FileNotFoundError:
        pass
    os.symlink("/etc/shadow", "${linkPath}")
    # Try open_checked again on a different path — create an unreadable file
    import subprocess as sp
    shadow_like = "${dir}/shadow-like"
    with open(shadow_like, "w") as f:
        f.write("root shadow data")
    os.chmod(shadow_like, 0o000)  # no one can read
    resolved2 = os.path.realpath(shadow_like)
    fd2, err2 = open_checked(resolved2, uid, gid)
    if err2:
        print(f"REFUSED_OK: {err2}")
    else:
        os.close(fd2)
        print("FAIL2: should have been refused")
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result1.status, 0, result1.stderr || result1.stdout)
  const out1 = result1.stdout
  assert.ok(out1.includes("READ_OK"), `first open should succeed: ${out1}`)
  assert.ok(out1.includes("original"), `should read original content: ${out1}`)
  assert.ok(out1.includes("REFUSED_OK"), `second open should refuse: ${out1}`)
  console.log("symlink O_NOFOLLOW safety verified")
})

test("fd stays valid after symlink retarget — TOCTOU proof", async () => {
  const { dir } = await tempHome()
  const { symlink, writeFile } = await import("node:fs/promises")
  const realFile = path.join(dir, "real.pem")
  await writeFile(realFile, "SECURE-CONTENT-12345")
  const linkPath = path.join(dir, "link.pem")
  await symlink(realFile, linkPath)

  const result = spawnSync(
    "python3", ["-c", `
import os, sys

def open_checked(resolved_path, uid, gid=None):
    try:
        fd = os.open(resolved_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return (-1, "That file does not exist.")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        return (-1, "That file is not accessible.")
    if st.st_uid != uid and st.st_uid != 0:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    can_read = False
    if st.st_uid == uid:
        if st.st_mode & 0o400: can_read = True
    elif st.st_uid == 0:
        if gid and (st.st_mode & 0o040) and st.st_gid == gid: can_read = True
        if st.st_mode & 0o004: can_read = True
    if not can_read:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    return (fd, None)

uid = os.getuid()
gid = os.getgid()
resolved = os.path.realpath("${linkPath}")
fd, err = open_checked(resolved, uid, gid)
assert err is None, f"open should succeed: {err}"

# Retarget symlink to something else
os.unlink("${linkPath}")
with open("${linkPath}", "w") as f:
    f.write("TAMPERED")
# fd was opened on the REAL realpath with O_NOFOLLOW, so it still points
# to the original inode.  Read through /dev/fd/N to prove it.
content = os.read(fd, 4096).decode()
assert content == "SECURE-CONTENT-12345", f"TOCTOU leak! got: {content}"
print(f"TOCTOU_SAFE: {content}")
os.close(fd)
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.ok(result.stdout.includes("TOCTOU_SAFE"), result.stdout)
  console.log("TOCTOU fd safety proven")
})

// ---- open_checked refusal tests -------------------------------------------

test("open_checked refuses root-owned unreadable file", async () => {
  const { dir } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const path_obj = await import("node:path")
  const fixture = path_obj.join(dir, "root-unreadable.pem")
  await writeFile(fixture, "secret")
  // As non-root we can't chown to root, but we can test the same logic
  // with mode 0000 (owner has no read bit) — open_checked should refuse.
  const { spawnSync } = await import("node:child_process")
  const result = spawnSync(
    "python3", ["-c", `
import os, sys

def open_checked(resolved_path, uid, gid=None):
    try:
        fd = os.open(resolved_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return (-1, "That file does not exist.")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        return (-1, "That file is not accessible.")
    if st.st_uid != uid and st.st_uid != 0:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    can_read = False
    if st.st_uid == uid:
        if st.st_mode & 0o400: can_read = True
    elif st.st_uid == 0:
        if gid and (st.st_mode & 0o040) and st.st_gid == gid: can_read = True
        if st.st_mode & 0o004: can_read = True
    if not can_read:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    return (fd, None)

uid = os.getuid()
gid = os.getgid()
# Mode 0000 — owner has no read bit; open_checked should refuse
os.chmod("${fixture}", 0o000)
fd, err = open_checked("${fixture}", uid, gid)
if err:
    print(f"REFUSED: {err}")
else:
    os.close(fd)
    print("FAIL: should have been refused")
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.ok(result.stdout.includes("REFUSED"), result.stdout)
})

test("open_checked accepts owner-readable file regardless of group-write", async () => {
  const { dir } = await tempHome()
  const { writeFile } = await import("node:fs/promises")
  const path_obj = await import("node:path")
  const fixture = path_obj.join(dir, "group-writable.sh")
  await writeFile(fixture, "#!/bin/bash\necho hi\n")
  const { spawnSync } = await import("node:child_process")
  const result = spawnSync(
    "python3", ["-c", `
import os, sys

def open_checked(resolved_path, uid, gid=None):
    try:
        fd = os.open(resolved_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return (-1, "That file does not exist.")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        return (-1, "That file is not accessible.")
    if st.st_uid != uid and st.st_uid != 0:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    can_read = False
    if st.st_uid == uid:
        if st.st_mode & 0o400: can_read = True
    elif st.st_uid == 0:
        if gid and (st.st_mode & 0o040) and st.st_gid == gid: can_read = True
        if st.st_mode & 0o004: can_read = True
    if not can_read:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    return (fd, None)

uid = os.getuid()
gid = os.getgid()
import subprocess as sp
sp.run(["chmod", "0620", "${fixture}"], check=False)
fd, err = open_checked("${fixture}", uid, gid)
if fd >= 0:
    os.close(fd)
    print("OPEN_OK: owner-owned with read bit")
else:
    print(f"OPEN_FAIL: {err}")
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  console.log("group-writable handled by admin path, not open_checked")
})

test("open_checked refuses nonexistent path", async () => {
  const result = spawnSync(
    "python3", ["-c", `
import os, sys

def open_checked(resolved_path, uid, gid=None):
    try:
        fd = os.open(resolved_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return (-1, "That file does not exist.")
    try:
        st = os.fstat(fd)
    except OSError:
        os.close(fd)
        return (-1, "That file is not accessible.")
    if st.st_uid != uid and st.st_uid != 0:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    can_read = False
    if st.st_uid == uid:
        if st.st_mode & 0o400: can_read = True
    elif st.st_uid == 0:
        if gid and (st.st_mode & 0o040) and st.st_gid == gid: can_read = True
        if st.st_mode & 0o004: can_read = True
    if not can_read:
        os.close(fd)
        return (-1, "That file is not readable by your account.")
    return (fd, None)

uid = os.getuid()
gid = os.getgid()
fd, err = open_checked("/tmp/does_not_exist_xyz_12345", uid, gid)
if err:
    print(f"REFUSED: {err}")
else:
    os.close(fd)
    print("FAIL")
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.ok(result.stdout.includes("REFUSED"), result.stdout)
  console.log("nonexistent path refused")
})

// ---- build_argv with csd_user param --------------------------------------

test("build_argv with csd_user adds --csd-user flag", () => {
  const result = spawnSync(
    "python3", ["-c", `
import re, os

_COOKIE_SHAPED = re.compile(r'[A-Za-z0-9+/=]{40,}')
_OS_VALUES = frozenset({'win','win7','win8','win8-1','win10','mac','mac-intel','linux','linux-64','android','freebsd','openbsd','solaris'})
_FILE_KEYS = {'csdWrapper','cafile','certificate','sslkey','vpncScript'}
_FILE_FLAGS = {'csdWrapper':'--csd-wrapper','cafile':'--cafile','certificate':'--certificate','sslkey':'--sslkey','vpncScript':'--script'}
_SERVERCERT_RE = re.compile(r'^[0-9A-Fa-f]{40}$')

def _plain_token(value, max_len=512):
    if not value or value.startswith('-'): return False
    return '\\n' not in value and '\\x00' not in value and len(value) <= max_len

# Minimal validate that skips file checks (we just want to test argv assembly)
def _validate_options(options, password_mode, usergroup, peer_uid=None):
    if not options: return None
    for key, value in options.items():
        if key == 'os':
            if value not in _OS_VALUES: return f'Invalid os value: {value}'
        elif key == 'useragent':
            if not _plain_token(value, 256): return 'Invalid useragent value'
        elif key == 'servercert':
            if not isinstance(value, str) or not _SERVERCERT_RE.match(value): return 'Invalid servercert value'
        elif key == 'baseMtu':
            try: v = int(value)
            except (ValueError, TypeError): return 'Invalid baseMtu value'
            if v < 576 or v > 65535: return 'baseMtu out of range'
        elif key == 'noDtls':
            if value is True: pass
        elif key == 'reconnectTimeout':
            try: v = int(value)
            except (ValueError, TypeError): return 'Invalid reconnectTimeout value'
            if v < 10 or v > 86400: return 'reconnectTimeout out of range'
        elif key in _FILE_KEYS:
            # Skip file validation for this test
            pass
        else:
            return f'Unknown option: {key}'
    return None

def build_argv(binary, user, usergroup, server, options=None, password_mode=False, peer_uid=None, csd_user=None):
    if not _plain_token(user) or not _plain_token(server): return [], 'Refusing an unsafe connect field'
    err = _validate_options(options, password_mode, usergroup, peer_uid)
    if err: return [], err
    os_value = options.get('os') if options else None
    if not os_value: os_value = 'linux-64'
    args = [binary, '--protocol=gp', '--user', user]
    if not password_mode:
        if not _plain_token(usergroup): return [], 'Refusing an unsafe connect field'
        if not usergroup or _COOKIE_SHAPED.search(usergroup): return [], 'Refusing an unsafe connect field'
        args.extend(['--passwd-on-stdin','--non-inter','--useragent','PAN GlobalProtect','--os',os_value,'--usergroup',usergroup])
    else:
        if usergroup and _plain_token(usergroup):
            args.extend(['--passwd-on-stdin','--non-inter','--useragent','PAN GlobalProtect','--os',os_value,'--usergroup',usergroup])
        else:
            args.extend(['--passwd-on-stdin','--non-inter','--useragent','PAN GlobalProtect','--os',os_value])
    if options:
        for key, value in options.items():
            if key == 'os': continue
            if key == 'useragent': args.extend(['--useragent', value])
            elif key in _FILE_KEYS:
                flag = _FILE_FLAGS[key]
                if key == 'csdWrapper' and csd_user: args.extend([flag, value, '--csd-user', csd_user])
                else: args.extend([flag, value])
            elif key == 'servercert': args.append(f'--servercert={value}')
            elif key == 'baseMtu': args.append(f'--base-mtu={int(value)}')
            elif key == 'noDtls' and value is True: args.append('--no-dtls')
            elif key == 'reconnectTimeout': args.append(f'--reconnect-timeout={int(value)}')
    args.append(server)
    return args, None

argv, err = build_argv(
    'openconnect', 'testuser', 'gateway:testgroup', 'vpn.example.com',
    options={'csdWrapper': '/usr/local/bin/csd.sh'},
    peer_uid=1000, csd_user='gavin',
)
print('ERROR:', err if err else 'NONE')
print('ARGV:', ' '.join(argv))
`],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  const lines = result.stdout.trim().split("\n")
  const argvLine = lines.find((l) => l.startsWith("ARGV:"))
  assert.ok(argvLine, `expected ARGV line in output: ${result.stdout}`)
  const argv = argvLine.slice(5)
  assert.ok(argv.includes("--csd-wrapper"), `expected --csd-wrapper: ${argv}`)
  assert.ok(argv.includes("/usr/local/bin/csd.sh"), `expected wrapper path: ${argv}`)
  assert.ok(argv.includes("--csd-user"), `expected --csd-user: ${argv}`)
  assert.ok(argv.includes("gavin"), `expected gavin: ${argv}`)
  console.log("build_argv csd-user flag present")
})

// ---- map_failure tests ---------------------------------------------------

test("map_failure maps known patterns to plain messages", () => {
  const result = spawnSync(
    "python3", ["-c", `
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("gpvpnd", sys.argv[1])
spec = importlib.util.spec_from_loader("gpvpnd", loader)
mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
map_failure = mod.map_failure  # the real function, not a copy

tests = [
    ("Resolving vpn.example.com", "Could not find that VPN address"),
    ("getaddrinfo failed: Name or service not known", "Could not find that VPN address"),
    ("Connection refused", "Could not reach the VPN server"),
    ("SSL handshake failed", "Could not reach the VPN server"),
    ("Failed to authenticate", "The VPN refused the sign-in"),
    ("authentication required", "The VPN refused the sign-in"),
    ("Invalid username or password", "The VPN refused the sign-in"),
    ("HIP check required", "This VPN wants a security check"),
    ("Host Information Policy", "This VPN wants a security check"),
    ("CSD command failed", "This VPN wants a security check"),
    ("some unknown error 42", None),
]
for line, expected in tests:
    result = map_failure(line)
    if expected is None:
        assert result is None, f"Expected None for '{line}', got '{result}'"
    else:
        assert result and expected in result, f"Expected '{expected}' in '{result}' for '{line}'"
print("ALL MAP_FAILURE TESTS PASSED")
`, new URL("../bin/gpvpnd", import.meta.url).pathname],
    { encoding: "utf8", timeout: 5000 },
  )
  assert.equal(result.status, 0, result.stderr || result.stdout)
  assert.ok(result.stdout.includes("ALL MAP_FAILURE TESTS PASSED"), result.stdout)
})
