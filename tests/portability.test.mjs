import test from "node:test"
import assert from "node:assert/strict"
import { readdir, readFile, stat } from "node:fs/promises"
import path from "node:path"
import { repo } from "./support.mjs"

const SKIP = new Set([".git", "node_modules", "__pycache__", ".qsroot", ".venv-harness"])
const TEXT = new Set([".md", ".json", ".qml", ".js", ".mjs", ".py", ".sh", ".service", ".socket", ".txt", ""])

async function files(dir, out = []) {
  for (const name of await readdir(dir)) {
    if (SKIP.has(name)) continue
    const full = path.join(dir, name)
    const info = await stat(full)
    if (info.isDirectory()) await files(full, out)
    else if (TEXT.has(path.extname(name)) || name === "gpvpn" || name === "gpvpnd" || name === "fake-openconnect") out.push(full)
  }
  return out
}

test("the tree has no real hosts, home paths, or stray emails", async () => {
  const host = ["pow", "erhrg"].join("")
  const home = `${path.sep}ho${"me"}${path.sep}`
  const hits = []
  for (const file of await files(repo)) {
    const text = await readFile(file, "utf8")
    if (text.includes(host)) hits.push(`${file}: employer host`)
    if (text.includes(home)) hits.push(`${file}: home path`)
    const emails = text.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) || []
    for (const email of emails) {
      if (email !== "user@example.com") hits.push(`${file}: ${email}`)
    }
  }
  assert.deepEqual(hits, [])
  console.log("portability scan clean")
})
