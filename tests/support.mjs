import { spawn } from "node:child_process"
import { mkdtemp, mkdir, writeFile, readFile } from "node:fs/promises"
import { existsSync } from "node:fs"
import { tmpdir } from "node:os"
import path from "node:path"
import net from "node:net"
import { fileURLToPath } from "node:url"

export const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")
export const gpvpn = path.join(repo, "bin", "gpvpn")
export const gpvpnd = path.join(repo, "bin", "gpvpnd")
export const fakeOpenconnect = path.join(repo, "tests", "fixtures", "fake-openconnect")
export const COOKIE = "AAAAfakeCookieValue0123456789abcdef====="

export const SAML_OK = `SAML response converted to OpenConnect command line invocation:

    echo ${COOKIE} |
        sudo openconnect --protocol=gp --user=user@example.com --os=linux --usergroup=gateway:prelogin-cookie --passwd-on-stdin vpn.example.com

SAML response converted to test-globalprotect-login.py invocation:
`

export async function tempHome() {
  const dir = await mkdtemp(path.join(tmpdir(), "omaglobal-"))
  const env = {
    ...process.env,
    HOME: dir,
    XDG_CONFIG_HOME: path.join(dir, "config"),
    XDG_CACHE_HOME: path.join(dir, "cache"),
    XDG_DATA_HOME: path.join(dir, "data"),
    XDG_STATE_HOME: path.join(dir, "state"),
  }
  await mkdir(path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui"), { recursive: true })
  return { dir, env }
}

export function run(bin, args, env, input) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, { env, stdio: ["pipe", "pipe", "pipe"] })
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (chunk) => { stdout += chunk })
    child.stderr.on("data", (chunk) => { stderr += chunk })
    child.on("error", reject)
    child.on("close", (code) => resolve({ code, stdout, stderr }))
    if (input !== undefined) child.stdin.end(input)
    else child.stdin.end()
  })
}

export async function writeSaml(env, body) {
  const script = path.join(env.XDG_DATA_HOME, "gp-vpn", "gp-saml-gui", "gp_saml_gui.py")
  const record = path.join(env.XDG_DATA_HOME, "saml-record.json")
  const source = `import json, os, sys
open(${JSON.stringify(record)}, "w").write(json.dumps({"argv": sys.argv, "env": {"GDK_BACKEND": os.environ.get("GDK_BACKEND"), "WEBKIT_DISABLE_DMABUF_RENDERER": os.environ.get("WEBKIT_DISABLE_DMABUF_RENDERER")}}))
sys.stdout.write(${JSON.stringify(body)})
`
  await writeFile(script, source)
  return { script, record }
}

export function collect(sockPath, payload, { until, timeout = 4000 } = {}) {
  return new Promise((resolve, reject) => {
    const messages = []
    const sock = net.createConnection(sockPath)
    let buf = ""
    let settled = false
    const finish = (err) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      sock.destroy()
      if (err) reject(err)
      else resolve(messages)
    }
    const timer = setTimeout(() => finish(), timeout)
    sock.on("connect", () => {
      if (payload) sock.write(JSON.stringify(payload) + "\n")
    })
    sock.on("data", (chunk) => {
      buf += chunk.toString("utf8")
      let nl
      while ((nl = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, nl)
        buf = buf.slice(nl + 1)
        if (!line.trim()) continue
        try {
          messages.push(JSON.parse(line))
        } catch {
          messages.push({ type: "error", message: "bad json" })
        }
        if (until && until(messages)) finish()
      }
    })
    sock.on("error", (err) => finish(err))
    sock.on("close", () => finish())
  })
}

export async function waitForDaemon(sock) {
  for (let i = 0; i < 50; i++) {
    if (existsSync(sock)) {
      try {
        const messages = await collect(sock, { cmd: "status" }, {
          until: (rows) => rows.length > 0,
          timeout: 300,
        })
        if (messages.length) return messages[0]
      } catch {
        // not listening yet
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 40))
  }
  throw new Error("daemon did not listen")
}

export function startDaemon(dir, env, mode = "ok", extraEnv = {}) {
  const sock = path.join(dir, "ctrl.sock")
  const ocDir = path.join(dir, "oc")
  const child = spawn(gpvpnd, [
    "--socket", sock,
    "--openconnect", fakeOpenconnect,
    "--state-file", path.join(dir, "state.json"),
  ], {
    env: {
      ...env,
      FAKE_OC_DIR: ocDir,
      FAKE_OC_MODE: mode,
      FAKE_OC_SLEEP: "30",
      ...extraEnv,
      // A leaked activation environment must not steal the test socket.
      LISTEN_FDS: "",
      LISTEN_PID: "",
      LISTEN_FDNAMES: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  })
  let stderr = ""
  child.stderr.on("data", (chunk) => { stderr += chunk })
  return { child, sock, ocDir, stderr: () => stderr }
}

export async function stopDaemon(child) {
  if (!child || child.killed || child.exitCode !== null) return
  child.kill("SIGTERM")
  await new Promise((resolve) => {
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
      resolve()
    }, 1500)
    child.on("close", () => {
      clearTimeout(timer)
      resolve()
    })
  })
}

export async function readText(file) {
  try {
    return await readFile(file, "utf8")
  } catch {
    return ""
  }
}
