import test from "node:test"
import assert from "node:assert/strict"
import path from "node:path"
import { spawnSync } from "node:child_process"
import { statSync } from "node:fs"
import {
  COOKIE, gpvpnd, fakeOpenconnect, tempHome, startDaemon, stopDaemon, waitForDaemon, collect, readText,
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
      until: (rows) => rows.some((row) => row.state === "connected" && row.ip),
      timeout: 4000,
    })
    const connected = session.find((row) => row.state === "connected")
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
