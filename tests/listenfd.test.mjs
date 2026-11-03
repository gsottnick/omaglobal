import test from "node:test"
import assert from "node:assert/strict"
import { spawn } from "node:child_process"
import { mkdtemp, stat } from "node:fs/promises"
import { tmpdir } from "node:os"
import path from "node:path"
import net from "node:net"
import { gpvpnd, fakeOpenconnect } from "./support.mjs"

// Hands the listening socket to gpvpnd the way systemd does: the client is
// already connected, and fd 3 is the ListenStream. The daemon must answer
// that client without unlinking the socket.
const ACTIVATE = `
import os, socket, sys
path, daemon, state, fake = sys.argv[1:5]
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
if os.path.exists(path):
    os.unlink(path)
sock.bind(path)
sock.listen(8)
print("INODE %s" % os.stat(path).st_ino, file=sys.stderr, flush=True)
if os.fork() == 0:
    sock.close()
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    client.connect(path)
    client.sendall(b'{"cmd":"status"}\\n')
    data = b""
    while b"\\n" not in data:
        chunk = client.recv(65536)
        if not chunk:
            break
        data += chunk
    sys.stdout.buffer.write(data)
    sys.stdout.flush()
    os._exit(0)
os.dup2(sock.fileno(), 3)
if sock.fileno() != 3:
    sock.close()
os.set_inheritable(3, True)
os.environ["LISTEN_PID"] = str(os.getpid())
os.environ["LISTEN_FDS"] = "1"
os.environ.pop("LISTEN_FDNAMES", None)
os.execv(daemon, [daemon, "--socket", path + ".unused", "--state-file", state, "--openconnect", fake])
`

function once(child) {
  return new Promise((resolve) => {
    let stdout = ""
    let stderr = ""
    child.stdout.on("data", (chunk) => { stdout += chunk })
    child.stderr.on("data", (chunk) => { stderr += chunk })
    const timer = setTimeout(() => {
      child.kill("SIGKILL")
    }, 4000)
    child.on("close", () => {
      clearTimeout(timer)
      resolve({ stdout, stderr })
    })
  })
}

test("a client connected before startup receives status", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "omaglobal-listen-"))
  const sockPath = path.join(dir, "ctrl.sock")
  const child = spawn("python3", [
    "-c", ACTIVATE, sockPath, gpvpnd, path.join(dir, "state.json"), fakeOpenconnect,
  ], { stdio: ["ignore", "pipe", "pipe"] })
  const done = once(child)
  const first = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("pre-connected client timed out")), 3500)
    const check = () => {
      // The forked client prints the daemon's reply. Wait until it arrives.
    }
    child.stdout.on("data", () => {
      clearTimeout(timer)
      resolve()
    })
    child.on("close", () => {
      clearTimeout(timer)
      reject(new Error("daemon exited before status"))
    })
    check()
  })
  void first
  const later = await new Promise((resolve, reject) => {
    const client = net.createConnection(sockPath)
    let buffer = ""
    const timer = setTimeout(() => {
      client.destroy()
      reject(new Error("later client timed out"))
    }, 2000)
    client.on("connect", () => client.write('{"cmd":"status"}\n'))
    client.on("data", (chunk) => {
      buffer += chunk.toString("utf8")
      if (buffer.includes("\n")) {
        clearTimeout(timer)
        client.end()
        resolve(buffer)
      }
    })
    client.on("error", (error) => {
      clearTimeout(timer)
      reject(error)
    })
  })
  child.kill("SIGTERM")
  const result = await done
  const inode = result.stderr.match(/INODE (\d+)/)
  assert.ok(inode, result.stderr)
  const after = await stat(sockPath)
  assert.equal(String(after.ino), inode[1])
  const queued = JSON.parse(result.stdout.split("\n")[0])
  const second = JSON.parse(later.split("\n")[0])
  assert.equal(queued.type, "state")
  assert.equal(queued.state, "idle")
  assert.equal(second.type, "state")
  assert.equal(second.state, "idle")
  console.log("pre-connected client received status")
})
