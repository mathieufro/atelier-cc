import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import { execFileSync } from "node:child_process"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import { fileURLToPath } from "node:url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SERVER_JS = path.resolve(__dirname, "../../mcp/server.js")

let wsp, pid, statePath, client, transport

beforeEach(async () => {
  wsp = fs.mkdtempSync(path.join(os.tmpdir(), "atelier-mcp-"))
  pid = "2026-05-14-test-a1b2"
  fs.mkdirSync(path.join(wsp, ".atelier", "pipelines", pid), { recursive: true })
  statePath = path.join(wsp, ".atelier", "pipelines", pid, "pipeline-state.json")
  fs.writeFileSync(statePath, JSON.stringify({
    id: pid, prompt: "x", workspacePath: wsp, status: "running", currentStage: "implement",
    type: "feature", createdAt: Date.now(), updatedAt: Date.now(),
    pipelineDir: `.atelier/pipelines/${pid}`,
    stepCounter: 1,
    sourceSessionId: "sess-self",
    stages: [{ id: "i1", stage: "implement", status: "running", startedAt: Date.now() }],
    fixAttempts: {}, stageModels: {}, stageModelsConfirmed: false,
  }))
  transport = new StdioClientTransport({
    command: "node", args: [SERVER_JS],
    env: { ...process.env, ATELIER_CC_WORKSPACE: wsp },
  })
  client = new Client({ name: "test", version: "0.0.0" }, { capabilities: {} })
  await client.connect(transport)
})

afterEach(async () => {
  await client?.close()
  fs.rmSync(wsp, { recursive: true, force: true })
})

describe("atelier_signal tool", () => {
  it("registers the tool with strict-superset schema", async () => {
    const tools = await client.listTools()
    const sig = tools.tools.find(t => t.name === "atelier_signal")
    expect(sig).toBeDefined()
    expect(sig.inputSchema.properties.type.const).toBe("stage_complete")
    expect(sig.inputSchema.properties.verdict.enum).toEqual(
      expect.arrayContaining(["done", "has_issues", "stuck", "proceed", "skip", "partial"])
    )
    expect(sig.inputSchema.properties.action.enum).toEqual(["implement", "done"])
    expect(sig.inputSchema.properties.outcome.enum).toEqual(["fixed", "fixed_unverified", "inconclusive"])
  })

  it("writes lastVerdict and completes the most recent stage", async () => {
    const outPath = path.join(wsp, ".atelier", "pipelines", pid, "01-impl.md")
    fs.writeFileSync(outPath, "ok")
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done", outputPath: outPath },
    })
    expect(res.content[0].text).toMatch(/Stage signal received/)
    expect(res.content[0].text).toMatch(/End your turn/)
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.lastVerdict).toBe("done")
    expect(state.lastOutputPath).toBe(outPath)
    expect(state.stages[0].verdict).toBe("done")
    expect(state.stages[0].status).toBe("completed")
    expect(typeof state.stages[0].completedAt).toBe("number")
  })

  it("partial verdict sets stage status to idle", async () => {
    const progress = path.join(wsp, ".atelier", "pipelines", pid, "progress.md")
    fs.writeFileSync(progress, "# Progress")
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "partial", outputPath: progress },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.stages[0].status).toBe("idle")
    expect(state.lastVerdict).toBe("partial")
  })

  it("stores pipelineType and worktreeChoice on classify signal (currentStage=null)", async () => {
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    state.currentStage = null
    fs.writeFileSync(statePath, JSON.stringify(state))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, pipelineType: "feature", worktreeChoice: "in-tree" },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.type).toBe("feature")
    expect(state.worktreeChoice).toBe("in-tree")
    expect(state.worktreePath).toBeFalsy()
  })

  it("classify with worktreeChoice=worktree provisions a git worktree", async () => {
    // Initialize a real git repo at wsp so `git worktree add` can succeed.
    execFileSync("git", ["-C", wsp, "init", "-q", "-b", "main"])
    execFileSync("git", ["-C", wsp, "config", "user.email", "t@t"])
    execFileSync("git", ["-C", wsp, "config", "user.name", "t"])
    fs.writeFileSync(path.join(wsp, "seed.txt"), "seed")
    execFileSync("git", ["-C", wsp, "add", "seed.txt"])
    execFileSync("git", ["-C", wsp, "commit", "-q", "-m", "seed"])
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    state.currentStage = null
    fs.writeFileSync(statePath, JSON.stringify(state))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, pipelineType: "feature", worktreeChoice: "worktree" },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.worktreeChoice).toBe("worktree")
    expect(state.worktreePath).toBe(path.join(wsp, ".atelier", "pipelines", pid, "worktree"))
    expect(fs.existsSync(state.worktreePath)).toBe(true)
    expect(fs.existsSync(path.join(state.worktreePath, "seed.txt"))).toBe(true)
    expect(state.gitBranch).toBe(`atelier/${pid}`)
    expect(state.gitBaseBranch).toBe("main")
    expect(state.gitBaseCommit).toMatch(/^[0-9a-f]{40}$/)
  })

  it("classify with worktreeChoice=worktree returns isError when workspace is not a git repo", async () => {
    // No git init — wsp is just a directory.
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    state.currentStage = null
    fs.writeFileSync(statePath, JSON.stringify(state))
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, pipelineType: "feature", worktreeChoice: "worktree" },
    })
    expect(res.isError).toBe(true)
    expect(res.content[0].text).toMatch(/git repository/i)
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.worktreePath).toBeFalsy()
  })

  it("stores currentStage on classify signal (start-at-stage branch)", async () => {
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    state.currentStage = null
    fs.writeFileSync(statePath, JSON.stringify(state))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, pipelineType: "feature", worktreeChoice: "in-tree", currentStage: "write_plan" },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.type).toBe("feature")
    expect(state.worktreeChoice).toBe("in-tree")
    expect(state.currentStage).toBe("write_plan")
    expect(state.lastVerdict).toBeFalsy()
  })

  it("ignores currentStage mid-pipeline (past classify gate)", async () => {
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    const originalStage = state.currentStage
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done", currentStage: "brainstorm" },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.currentStage).toBe(originalStage)
    expect(res.content[0].text).toMatch(/ignored/)
  })

  it("ignores pipelineType/worktreeChoice mid-pipeline (currentStage != null)", async () => {
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    const originalType = state.type
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done", pipelineType: "other-topology" },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.type).toBe(originalType)
    expect(state.lastVerdict).toBe("done")
    expect(res.content[0].text).toMatch(/ignored/)
  })

  it("duplicate completion signal is an idempotent no-op (does not re-stamp)", async () => {
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done", outputPath: path.join(wsp, ".atelier", "pipelines", pid, "01-impl.md") },
    })
    // Second signal for the now-completed stage must change nothing.
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "stuck" },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(res.content[0].text).toMatch(/ignored/)
    expect(state.lastVerdict).toBe("done")        // not overwritten with "stuck"
    expect(state.stages[0].verdict).toBe("done")
    expect(state.stages[0].status).toBe("completed")
  })

  it("stale signal does NOT poison a freshly-appended, never-launched next stage row (mit-relicensing regression)", async () => {
    // Exact shape of the corruption: review completed, fix_* row appended by
    // SubagentStop but never launched (compiledPromptPath null). The review
    // worker fires a 2nd signal; it must NOT mark the fix stage completed.
    const st = JSON.parse(fs.readFileSync(statePath, "utf8"))
    st.currentStage = "fix_quick_plan"
    st.expectedMode = "autonomous"
    st.lastVerdict = null
    st.stages = [
      { id: "r1", stage: "review_quick_plan", status: "completed", verdict: "has_issues", compiledPromptPath: "/tmp/r.md" },
      { id: "f1", stage: "fix_quick_plan", status: "running", compiledPromptPath: null, sessionId: null },
    ]
    fs.writeFileSync(statePath, JSON.stringify(st))
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "has_issues" },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(res.content[0].text).toMatch(/ignored/)
    expect(state.stages[1].status).toBe("running")     // fix row untouched
    expect(state.stages[1].verdict).toBeUndefined()
    expect(state.lastVerdict).toBe(null)               // not advanced
  })

  it("legit autonomous signal applies once the worker was actually launched (compiledPromptPath set)", async () => {
    const st = JSON.parse(fs.readFileSync(statePath, "utf8"))
    st.currentStage = "fix_quick_plan"
    st.expectedMode = "autonomous"
    st.stages = [{ id: "f1", stage: "fix_quick_plan", status: "running", compiledPromptPath: "/tmp/f.md", sessionId: null }]
    fs.writeFileSync(statePath, JSON.stringify(st))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done" },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.stages[0].status).toBe("completed")
    expect(state.stages[0].verdict).toBe("done")
    expect(state.lastVerdict).toBe("done")
  })

  it("stores action for plan-gate", async () => {
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, action: "implement" },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.lastAction).toBe("implement")
  })

  it("stores outcome for bugfix", async () => {
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, outcome: "fixed", verdict: "done" },
    })
    const state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.lastOutcome).toBe("fixed")
  })

  it("rejects atelier_signal without pipelineId", async () => {
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", verdict: "done" },
    })
    expect(res.isError).toBe(true)
    expect(res.content[0].text).toMatch(/pipelineId/i)
  })

  it("returns error when pipelineId does not exist", async () => {
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: "2026-05-14-nope-9999", verdict: "done" },
    })
    expect(res.isError).toBe(true)
    expect(res.content[0].text).toMatch(/pipeline not found/i)
  })

  it("routes by explicit pipelineId, not by any pointer file", async () => {
    const pid2 = "2026-05-14-test-zzzz"
    const dir2 = path.join(wsp, ".atelier", "pipelines", pid2)
    fs.mkdirSync(dir2, { recursive: true })
    const sp2 = path.join(dir2, "pipeline-state.json")
    fs.writeFileSync(sp2, JSON.stringify({
      id: pid2, prompt: "y", status: "running", currentStage: "x", type: "feature",
      sourceSessionId: "sess-other",
      stages: [{ id: "s1", stage: "x", status: "running" }],
      fixAttempts: {}, stageModels: {}, stageModelsConfirmed: false,
      createdAt: Date.now(), updatedAt: Date.now(),
    }))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid2, verdict: "done" },
    })
    expect(JSON.parse(fs.readFileSync(sp2, "utf8")).lastVerdict).toBe("done")
    expect(JSON.parse(fs.readFileSync(statePath, "utf8")).lastVerdict).toBeFalsy()
  })

  it("flags missing required artifact but still records verdict", async () => {
    const stagedPath = path.join(wsp, ".atelier", "pipelines", pid, "missing.md")
    let state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    state.stages[0].assignedOutputPath = stagedPath
    fs.writeFileSync(statePath, JSON.stringify(state))
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done", outputPath: stagedPath },
    })
    state = JSON.parse(fs.readFileSync(statePath, "utf8"))
    expect(state.stages[0].status).toBe("stuck")
    expect(state.stages[0].error).toMatch(/missing artifact/)
    expect(state.lastVerdict).toBe("done")
  })

  it("atomic write does not leave .tmp on success", async () => {
    await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done" },
    })
    const dir = path.dirname(statePath)
    const tmpFiles = fs.readdirSync(dir).filter(f => f.includes(".tmp"))
    expect(tmpFiles).toEqual([])
  })

  it("rejects invalid arguments via zod", async () => {
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "wrong_type" },
    })
    expect(res.isError).toBe(true)
    expect(res.content[0].text).toMatch(/invalid_literal|stage_complete/)
  })
})
