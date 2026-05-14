#!/usr/bin/env node
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js"
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js"
import { z } from "zod"
import * as fs from "node:fs"
import * as path from "node:path"
import { execFileSync } from "node:child_process"
import { acquireLock, releaseLock } from "./lock.js"

const server = new McpServer({ name: "atelier", version: "0.1.0" })

const inputSchema = {
  type: z.literal("stage_complete"),
  pipelineId: z.string().min(1),
  outputPath: z.string().optional(),
  verdict: z.enum(["done", "has_issues", "stuck", "proceed", "skip", "partial"]).optional(),
  action: z.enum(["implement", "done"]).optional(),
  outcome: z.enum(["fixed", "fixed_unverified", "inconclusive"]).optional(),
  pipelineType: z.string().optional(),
  worktreeChoice: z.enum(["in-tree", "worktree"]).optional(),
}

function workspaceRoot() {
  // Plugin manifest sets ATELIER_CC_WORKSPACE = ${CLAUDE_PROJECT_DIR}; that is
  // the only correct path. Falling back to process.cwd() silently picks
  // wherever node was launched from, which is rarely the workspace. Use cwd()
  // only when it actually contains an .atelier/ directory — otherwise refuse.
  if (process.env.ATELIER_CC_WORKSPACE) return process.env.ATELIER_CC_WORKSPACE
  const cwd = process.cwd()
  if (fs.existsSync(path.join(cwd, ".atelier"))) return cwd
  throw new Error(
    "ATELIER_CC_WORKSPACE env var is unset and cwd has no .atelier/ directory. " +
    "The MCP server must be launched by Claude Code (which provides the env var) " +
    "or from inside an Atelier workspace."
  )
}

function readState(wsp, pid) {
  const p = path.join(wsp, ".atelier", "pipelines", pid, "pipeline-state.json")
  return { path: p, data: JSON.parse(fs.readFileSync(p, "utf8")) }
}

// Atomic per-write but NOT serialized against concurrent hook writers — see
// lib/pipeline-state.sh's concurrency note. v1 relies on Claude Code
// serializing MCP/SubagentStop/Stop invocations so this read-modify-write
// pattern is race-free in practice. Revisit for multi-pipeline v1.x.
function atomicWriteState(p, data) {
  const tmp = `${p}.tmp.${process.pid}`
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2))
  fs.renameSync(tmp, p)
}

// Materialize a git worktree at .atelier/pipelines/<pid>/worktree/ when the
// classify signal selects worktree mode. Stamps gitBranch / gitBaseBranch /
// gitBaseCommit / worktreePath so compile-prompt can use the isolated tree.
// No-op for in-tree mode or when a worktree is already provisioned.
function setupWorktreeIfNeeded(state, wsp, pid) {
  if (state.worktreeChoice !== "worktree") return
  if (state.worktreePath) return
  try {
    execFileSync("git", ["-C", wsp, "rev-parse", "--show-toplevel"], { stdio: "pipe" })
  } catch {
    throw new Error("worktree mode requires a git repository; workspace is not a git working tree")
  }
  const branch = `atelier/${pid}`
  const wtPath = path.join(wsp, ".atelier", "pipelines", pid, "worktree")
  const baseCommit = execFileSync("git", ["-C", wsp, "rev-parse", "HEAD"], { encoding: "utf8" }).trim()
  let baseBranch = null
  try {
    const b = execFileSync("git", ["-C", wsp, "rev-parse", "--abbrev-ref", "HEAD"], { encoding: "utf8" }).trim()
    if (b && b !== "HEAD") baseBranch = b
  } catch {}
  execFileSync("git", ["-C", wsp, "worktree", "add", "-b", branch, wtPath, baseCommit], { stdio: "pipe" })
  state.worktreePath = wtPath
  state.gitBranch = branch
  state.gitBaseBranch = baseBranch
  state.gitBaseCommit = baseCommit
}

server.registerTool(
  "atelier_signal",
  {
    description: "Signal the Atelier orchestrator. Call when you have completed your stage and written your output artifact.",
    inputSchema,
  },
  async (args) => {
    let wsp
    try {
      wsp = workspaceRoot()
    } catch (e) {
      return { isError: true, content: [{ type: "text", text: e.message }] }
    }
    const pid = args.pipelineId
    const spPath = path.join(wsp, ".atelier", "pipelines", pid, "pipeline-state.json")
    if (!fs.existsSync(spPath)) {
      return { isError: true, content: [{ type: "text", text: `pipeline not found: ${pid}` }] }
    }
    let classifyIgnored = false
    try {
      await acquireLock(spPath)
    } catch (e) {
      return { isError: true, content: [{ type: "text", text: `Failed to acquire pipeline lock: ${e.message}` }] }
    }
    try {
      let state
      try {
        state = JSON.parse(fs.readFileSync(spPath, "utf8"))
      } catch (e) {
        return { isError: true, content: [{ type: "text", text: `Failed to read pipeline-state.json: ${e.message}` }] }
      }
      const now = Date.now()
      state.updatedAt = now
      state.lastHeartbeatMs = now
      if (args.verdict !== undefined) state.lastVerdict = args.verdict
      if (args.outputPath !== undefined) state.lastOutputPath = args.outputPath
      if (args.action !== undefined) state.lastAction = args.action
      if (args.outcome !== undefined) state.lastOutcome = args.outcome

      if (args.pipelineType !== undefined || args.worktreeChoice !== undefined) {
        if (state.currentStage == null) {
          if (args.pipelineType !== undefined) state.type = args.pipelineType
          if (args.worktreeChoice !== undefined) state.worktreeChoice = args.worktreeChoice
          try {
            setupWorktreeIfNeeded(state, wsp, pid)
          } catch (e) {
            return { isError: true, content: [{ type: "text", text: `Failed to create worktree: ${e.message}` }] }
          }
        } else {
          classifyIgnored = true
        }
      }

      const stages = state.stages || []
      const last = stages[stages.length - 1]
      if (last) {
        if (args.verdict !== undefined) last.verdict = args.verdict
        if (args.outputPath !== undefined) last.outputPath = args.outputPath
        last.completedAt = now
        last.status = args.verdict === "partial" ? "idle" : "completed"
        if (last.assignedOutputPath && args.outputPath && !fs.existsSync(args.outputPath)) {
          last.status = "stuck"
          last.error = `missing artifact: ${args.outputPath}`
        }
      }

      try {
        atomicWriteState(spPath, state)
      } catch (e) {
        return { isError: true, content: [{ type: "text", text: `Failed to write state: ${e.message}` }] }
      }
    } finally {
      releaseLock(spPath)
    }
    const text = classifyIgnored
      ? "Stage signal received. (pipelineType/worktreeChoice ignored — pipeline already past classify gate.) STOP YOUR TURN IMMEDIATELY — no further output or tool calls."
      : "Stage signal received. STOP YOUR TURN IMMEDIATELY — no further output or tool calls."
    return { content: [{ type: "text", text }] }
  }
)

const transport = new StdioServerTransport()
await server.connect(transport)
