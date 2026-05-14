import { describe, it, expect, beforeEach, afterEach } from "vitest"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import { acquireLock, releaseLock } from "../../mcp/lock.js"

let dir
beforeEach(() => { dir = fs.mkdtempSync(path.join(os.tmpdir(), "lk-")) })
afterEach(() => { fs.rmSync(dir, { recursive: true, force: true }) })

describe("acquireLock / releaseLock", () => {
  it("creates and removes the lock dir", async () => {
    const f = path.join(dir, "state.json"); fs.writeFileSync(f, "{}")
    await acquireLock(f)
    expect(fs.existsSync(`${f}.lock`)).toBe(true)
    releaseLock(f)
    expect(fs.existsSync(`${f}.lock`)).toBe(false)
  })

  it("breaks stale locks older than 30s", async () => {
    const f = path.join(dir, "s"); fs.writeFileSync(f, "{}")
    fs.mkdirSync(`${f}.lock`)
    const old = new Date(Date.now() - 60_000)
    fs.utimesSync(`${f}.lock`, old, old)
    await acquireLock(f)
    releaseLock(f)
  })

  it("rejects on timeout against a live lock", async () => {
    const f = path.join(dir, "s"); fs.writeFileSync(f, "{}")
    fs.mkdirSync(`${f}.lock`)
    await expect(acquireLock(f, 200)).rejects.toThrow(/lock timeout/)
  })
})
