#!/usr/bin/env node
// Cross-platform hook runner.
//
// On macOS/Linux: runs the .sh script directly via `bash` (already on PATH).
// On Windows: `bash` in cmd.exe/PowerShell resolves to C:\Windows\System32\bash.exe
// (the WSL launcher), NOT Git Bash. This script finds the Git Bash binary and
// uses it instead, so hooks run in a proper POSIX shell without spinning up WSL.
import { spawnSync, execFileSync } from 'node:child_process'
import { existsSync } from 'node:fs'
import { dirname, join } from 'node:path'

const scriptPath = process.argv[2]
if (!scriptPath) {
  process.stderr.write('run-hook.js: missing script path argument\n')
  process.exit(1)
}

function findGitBash() {
  // Locate git.exe, then walk up its parent directories looking for bash.exe.
  // Git for Windows places git.exe at various depths inside the installation
  // (e.g. <root>\cmd\git.exe, <root>\bin\git.exe, <root>\mingw64\bin\git.exe),
  // but bash.exe is always at <root>\bin\bash.exe or <root>\usr\bin\bash.exe.
  try {
    const gitExe = execFileSync('where', ['git'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).split(/\r?\n/)[0].trim()
    if (gitExe) {
      let dir = dirname(gitExe)
      for (let depth = 0; depth < 5; depth++) {
        dir = dirname(dir)
        for (const rel of ['bin\\bash.exe', 'usr\\bin\\bash.exe']) {
          const candidate = join(dir, rel)
          if (existsSync(candidate)) return candidate
        }
      }
    }
  } catch { /* where.exe or git not found */ }

  // Fallback: well-known default install locations.
  for (const p of [
    'C:\\Program Files\\Git\\bin\\bash.exe',
    'C:\\Program Files\\Git\\usr\\bin\\bash.exe',
    'C:\\Program Files (x86)\\Git\\bin\\bash.exe',
  ]) {
    if (existsSync(p)) return p
  }
  return null
}

const bash = process.platform === 'win32' ? (findGitBash() ?? 'bash') : 'bash'
const result = spawnSync(bash, [scriptPath], { stdio: 'inherit' })
process.exit(result.status ?? (result.error ? 1 : 0))
