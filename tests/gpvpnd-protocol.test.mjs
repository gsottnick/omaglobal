import test from "node:test"
import assert from "node:assert/strict"
import path from "node:path"
import {
  COOKIE, tempHome, startDaemon, stopDaemon, waitForDaemon, collect, readText,
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
