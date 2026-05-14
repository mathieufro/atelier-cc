import * as fs from "node:fs"

export const LOCK_TIMEOUT_MS = 5000
export const LOCK_STALE_MS = 30_000

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

export async function acquireLock(statePath, timeoutMs = LOCK_TIMEOUT_MS) {
  const lock = `${statePath}.lock`
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      fs.mkdirSync(lock)
      return lock
    } catch (e) {
      if (e.code !== "EEXIST") throw e
      try {
        const age = Date.now() - fs.statSync(lock).mtimeMs
        if (age > LOCK_STALE_MS) {
          try { fs.rmdirSync(lock) } catch {}
          continue
        }
      } catch {}
      if (Date.now() > deadline) throw new Error(`lock timeout: ${lock}`)
      await sleep(50)
    }
  }
}

export function releaseLock(statePath) {
  try { fs.rmdirSync(`${statePath}.lock`) } catch {}
}
