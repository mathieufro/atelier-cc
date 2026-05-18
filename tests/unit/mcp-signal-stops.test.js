import { describe, it, expect } from "vitest"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js"
import * as fs from "node:fs"
import * as path from "node:path"
import * as os from "node:os"
import { fileURLToPath } from "node:url"

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const SERVER_JS = path.resolve(__dirname, "../../mcp/server.js")

describe("MCP signal stop-the-turn text (regression)", () => {
  it("instructs a concrete turn-ending act, not the self-defeating 'no output'", async () => {
    const wsp = fs.mkdtempSync(path.join(os.tmpdir(), "atelier-reg-"))
    const pid = "2026-05-14-x-a1b2"
    fs.mkdirSync(path.join(wsp, ".atelier", "pipelines", pid), { recursive: true })
    fs.writeFileSync(path.join(wsp, ".atelier", "pipelines", pid, "pipeline-state.json"), JSON.stringify({
      id: pid, status: "running", prompt: "x", type: "feature",
      stages: [{ id: "s1", stage: "x", status: "running" }],
      pipelineDir: `.atelier/pipelines/${pid}`, workspacePath: wsp,
      createdAt: Date.now(), updatedAt: Date.now(),
    }))
    const transport = new StdioClientTransport({
      command: "node", args: [SERVER_JS],
      env: { ...process.env, ATELIER_CC_WORKSPACE: wsp },
    })
    const client = new Client({ name: "reg", version: "0.0.0" }, { capabilities: {} })
    await client.connect(transport)
    const res = await client.callTool({
      name: "atelier_signal",
      arguments: { type: "stage_complete", pipelineId: pid, verdict: "done" },
    })
    const text = res.content[0].text
    expect(text).toContain("Stage signal received")
    // Must give the model a concrete terminal act so the turn actually ends
    // (that is what fires Stop / SubagentStop).
    expect(text).toContain("End your turn")
    expect(text).toContain("Stage complete.")
    // The old wording forbade ALL output, which left a subagent no way to emit
    // the final message that closes its turn — it looped in thinking and the
    // pipeline wedged. That self-defeating instruction must be gone.
    expect(text).not.toContain("no further output")
    expect(text).not.toContain("no further tool calls")
    await client.close()
    fs.rmSync(wsp, { recursive: true, force: true })
  })
})
