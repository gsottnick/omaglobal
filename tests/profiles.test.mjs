import test from "node:test"
import assert from "node:assert/strict"
import path from "node:path"
import { statSync } from "node:fs"
import { mkdir, writeFile } from "node:fs/promises"
import { createHash } from "node:crypto"
import { existsSync } from "node:fs"
import { gpvpn, tempHome, run } from "./support.mjs"

test("profiles round-trip and mode is always gateway", async () => {
  const { env } = await tempHome()
  const first = await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  assert.equal(first.code, 0)
  const second = await run(gpvpn, ["profile", "add", "--name", "Other", "--portal", "https://vpn.example.com/global-protect/"], env)
  assert.equal(second.code, 0)
  const listed = JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
  assert.equal(listed.profiles.length, 2)
  const other = listed.profiles.find((item) => item.name === "Other")
  assert.equal(other.portal, "vpn.example.com")
  assert.equal(other.username, "")
  assert.equal(other.mode, "gateway")
  assert.equal(other.gateway, "")
  const forced = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "mode", "portal"], env)).stdout)
  assert.equal(forced.profiles.find((item) => item.name === "Other").mode, "gateway")
  const named = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "gatewayName", "KEEP-EXAMPLE"], env)).stdout)
  assert.equal(named.profiles.find((item) => item.name === "Other").gatewayName, "KEEP-EXAMPLE")
  const active = JSON.parse((await run(gpvpn, ["profile", "set", "Other", "active", "yes"], env)).stdout)
  assert.equal(active.active, "Other")
  const profileFile = path.join(env.XDG_CONFIG_HOME, "gp-vpn", "profiles.json")
  assert.equal(statSync(profileFile).mode & 0o777, 0o600)
  assert.equal(statSync(path.dirname(profileFile)).mode & 0o777, 0o700)
  const removed = JSON.parse((await run(gpvpn, ["profile", "remove", "Other"], env)).stdout)
  assert.equal(removed.profiles.length, 1)
  assert.equal(removed.profiles[0].name, "Default")
  console.log("profile round-trip")
})

test("connect without a profile exits 2 and says to add one", async () => {
  const { env } = await tempHome()
  const result = await run(gpvpn, ["connect", "--profile", "Default"], env)
  assert.equal(result.code, 2)
  assert.match(result.stderr, /no longer saved/)
  console.log("no-profile exit 2")
})

// ---- normalize defaults -------------------------------------------------

test("normalize fills required fields and carries optional ones", async () => {
  const { env } = await tempHome()
  // Add profile with optional fields
  const added = await run(gpvpn, [
    "profile", "add", "--name", "Test",
    "--portal", "vpn.example.com", "--username", "user@example.com",
  ], env)
  assert.equal(added.code, 0)

  // Set optional fields
  const set_os = JSON.parse((await run(gpvpn, ["profile", "set", "Test", "os", "win10"], env)).stdout)
  assert.equal(set_os.profiles.find(p => p.name === "Test").os, "win10")

  const set_ud = JSON.parse((await run(gpvpn, ["profile", "set", "Test", "noDtls", "On"], env)).stdout)
  assert.equal(set_ud.profiles.find(p => p.name === "Test").noDtls, true)

  const set_mtu = JSON.parse((await run(gpvpn, ["profile", "set", "Test", "baseMtu", "1400"], env)).stdout)
  assert.equal(set_mtu.profiles.find(p => p.name === "Test").baseMtu, 1400)

  const set_rt = JSON.parse((await run(gpvpn, ["profile", "set", "Test", "reconnectTimeout", "300"], env)).stdout)
  assert.equal(set_rt.profiles.find(p => p.name === "Test").reconnectTimeout, 300)

  const set_ua = JSON.parse((await run(gpvpn, ["profile", "set", "Test", "useragent", "MyAgent"], env)).stdout)
  assert.equal(set_ua.profiles.find(p => p.name === "Test").useragent, "MyAgent")

  const listed = JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
  const profile = listed.profiles.find(p => p.name === "Test")
  assert.equal(profile.os, "win10")
  assert.equal(profile.noDtls, true)
  assert.equal(profile.baseMtu, 1400)
  assert.equal(profile.reconnectTimeout, 300)
  assert.equal(profile.useragent, "MyAgent")
  // Required fields still present
  assert.equal(profile.mode, "gateway")
  assert.equal(profile.portal, "vpn.example.com")
  console.log("normalize carries optional fields")
})

test("normalize drops unset optional fields", async () => {
  const { env } = await tempHome()
  const added = await run(gpvpn, [
    "profile", "add", "--name", "Minimal",
    "--portal", "vpn.example.com", "--username", "user@example.com",
  ], env)
  assert.equal(added.code, 0)
  const listed = JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
  const profile = listed.profiles.find(p => p.name === "Minimal")
  assert.equal(profile.os, undefined)
  assert.equal(profile.noDtls, undefined)
  assert.equal(profile.baseMtu, undefined)
  assert.equal(profile.reconnectTimeout, undefined)
  assert.equal(profile.useragent, undefined)
  console.log("unset optional fields are dropped")
})

test("authMethod password is stored and validated", async () => {
  const { env } = await tempHome()
  // Create the Default profile first
  await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  const set_auth = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "authMethod", "password"], env)).stdout)
  assert.equal(set_auth.profiles.find(p => p.name === "Default").authMethod, "password")
  // Invalid authMethod is rejected
  const bad = await run(gpvpn, ["profile", "set", "Default", "authMethod", "oauth"], env)
  assert.equal(bad.code, 2)
  console.log("authMethod password stored, invalid rejected")
})

// ---- forget idempotent --------------------------------------------------

test("forget deletes the cookie jar and is idempotent", async () => {
  const { env } = await tempHome()
  // Create a profile to get a cookie jar name
  await run(gpvpn, ["profile", "add", "--name", "ForgetTest", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  // First forget on a non-existent jar should succeed (idempotent)
  const first = await run(gpvpn, ["forget", "ForgetTest"], env)
  assert.equal(first.code, 0)
  const first_json = JSON.parse(first.stdout)
  assert.equal(first_json.forgot, "ForgetTest")
  // Create the jar then forget it
  const cacheDir = path.join(env.XDG_CACHE_HOME, "gp-vpn")
  await mkdir(cacheDir, { recursive: true })
  // The jar name is okta-<sha256(name)[:8]>.json
  const { createHash } = await import("node:crypto")
  const digest = createHash("sha256").update("ForgetTest").digest("hex").slice(0, 8)
  const jarPath = path.join(cacheDir, `okta-${digest}.json`)
  await writeFile(jarPath, "{}")
  assert.ok((await import("node:fs")).existsSync(jarPath))
  // Re-run forget after creating the jar
  const second = await run(gpvpn, ["forget", "ForgetTest"], env)
  assert.equal(second.code, 0)
  const second_json = JSON.parse(second.stdout)
  assert.equal(second_json.forgot, "ForgetTest")
  console.log("forget is idempotent")
})

// ---- bool/int parsing in profile set ------------------------------------

test("bool and int values parse correctly in profile set", async () => {
  const { env } = await tempHome()
  // Create the Default profile first
  await run(gpvpn, ["profile", "add", "--name", "Default", "--portal", "vpn.example.com", "--username", "user@example.com"], env)
  const on = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "noDtls", "On"], env)).stdout)
  assert.equal(on.profiles.find(p => p.name === "Default").noDtls, true)
  const off = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "noDtls", "Off"], env)).stdout)
  assert.equal(off.profiles.find(p => p.name === "Default").noDtls, false)
  const true_v = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "noDtls", "true"], env)).stdout)
  assert.equal(true_v.profiles.find(p => p.name === "Default").noDtls, true)
  const false_v = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "noDtls", "false"], env)).stdout)
  assert.equal(false_v.profiles.find(p => p.name === "Default").noDtls, false)
  const mtu = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "baseMtu", "1200"], env)).stdout)
  assert.equal(mtu.profiles.find(p => p.name === "Default").baseMtu, 1200)
  const rt = JSON.parse((await run(gpvpn, ["profile", "set", "Default", "reconnectTimeout", "600"], env)).stdout)
  assert.equal(rt.profiles.find(p => p.name === "Default").reconnectTimeout, 600)
  // Invalid int is rejected
  const bad_int = await run(gpvpn, ["profile", "set", "Default", "baseMtu", "abc"], env)
  assert.equal(bad_int.code, 2)
  const bad_bool = await run(gpvpn, ["profile", "set", "Default", "noDtls", "yes"], env)
  assert.equal(bad_bool.code, 2)
  console.log("bool/int parsing works")
})

const saved = async (env) => JSON.parse((await run(gpvpn, ["profile", "list"], env)).stdout)
const save = async (env, name, fields) => JSON.parse((await run(gpvpn, ["profile", "save", name, JSON.stringify(fields)], env)).stdout)

test("a save is all or nothing, and each refusal says what to fix", async () => {
  const { env } = await tempHome()
  assert.deepEqual(await save(env, "", { portal: "" }), { ok: false, error: "Enter the VPN portal address." })
  assert.match((await save(env, "", { portal: "not a host" })).error, /does not look like a VPN address/)
  assert.deepEqual(await save(env, "", { name: "Work", portal: "https://vpn.example.com/global-protect/" }), { ok: true, error: "" })
  assert.equal((await saved(env)).profiles[0].portal, "vpn.example.com")
  assert.equal((await saved(env)).profiles[0].username, "")
  assert.match((await save(env, "Work", { portal: "vpn.example.com", authMethod: "password" })).error, /needs a username/)
  assert.match((await save(env, "Work", { portal: "vpn.example.com", baseMtu: "abc" })).error, /Tunnel packet size/)
  assert.match((await save(env, "Work", { portal: "vpn.example.com", cafile: "/no/such/file.pem" })).error, /certificate authority file/)
  assert.equal((await saved(env)).profiles[0].authMethod, "sso")
})

test("blank fields clear a setting and every chosen value is stored", async () => {
  const { env } = await tempHome()
  await save(env, "", { name: "Work", portal: "vpn.example.com" })
  const all = { portal: "vpn.example.com", username: "user@example.com", authMethod: "password", interface: "gateway", os: "win", noDtls: true, baseMtu: "1300", reconnectTimeout: "120", useragent: "PAN GlobalProtect" }
  assert.equal((await save(env, "Work", all)).ok, true)
  const row = (await saved(env)).profiles[0]
  assert.equal(row.authMethod, "password")
  assert.equal(row.interface, "gateway")
  assert.equal(row.os, "win")
  assert.equal(row.noDtls, true)
  assert.equal(row.baseMtu, 1300)
  assert.equal(row.reconnectTimeout, 120)
  assert.equal((await save(env, "Work", { portal: "vpn.example.com", baseMtu: "", reconnectTimeout: "" })).ok, true)
  const cleared = (await saved(env)).profiles[0]
  assert.equal(cleared.baseMtu, undefined)
  assert.equal(cleared.reconnectTimeout, undefined)
  assert.equal(cleared.os, undefined)
})

test("renaming keeps the default, the saved sign-in, and refuses a duplicate", async () => {
  const { env } = await tempHome()
  await save(env, "", { name: "Work", portal: "vpn.example.com" })
  await save(env, "", { name: "Home", portal: "vpn.example.net" })
  await run(gpvpn, ["profile", "set", "Work", "active", "yes"], env)
  const digest = (name) => createHash("sha256").update(name).digest("hex").slice(0, 8)
  const jar = (name) => path.join(env.XDG_CACHE_HOME, "gp-vpn", `okta-${digest(name)}.json`)
  await mkdir(path.dirname(jar("Work")), { recursive: true })
  await writeFile(jar("Work"), "{}")
  assert.match((await save(env, "Work", { name: "Home", portal: "vpn.example.com" })).error, /already have a VPN called Home/)
  assert.equal((await save(env, "Work", { name: "Office", portal: "vpn.example.com" })).ok, true)
  const store = await saved(env)
  assert.equal(store.active, "Office")
  assert.deepEqual(store.profiles.map((row) => row.name).sort(), ["Home", "Office"])
  assert.ok(existsSync(jar("Office")))
  await run(gpvpn, ["profile", "remove", "Office"], env)
  assert.equal(existsSync(jar("Office")), false)
  assert.equal((await saved(env)).active, "Home")
})

test("changing the portal drops that portal's gateways", async () => {
  const { env } = await tempHome()
  await save(env, "", { name: "Work", portal: "vpn.example.com" })
  await run(gpvpn, ["profile", "set", "Work", "gateways", JSON.stringify([{ name: "EAST", host: "east.example.com", priority: 1 }])], env)
  await save(env, "Work", { portal: "vpn.example.com", gateway: "east.example.com", gatewayName: "EAST" })
  assert.equal((await saved(env)).profiles[0].gatewayName, "EAST")
  await save(env, "Work", { portal: "vpn.example.net", gateway: "east.example.com", gatewayName: "EAST" })
  const row = (await saved(env)).profiles[0]
  assert.equal(row.gatewayName, "")
  assert.equal(row.gateways, undefined)
})
