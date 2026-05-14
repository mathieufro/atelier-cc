# atelier-cc

Claude Code plugin port of [Atelier](https://github.com/mathieufro/atelier). Brings Atelier's four pipeline types (Quick Plan, Task, Feature, Epic) plus the standalone `bugfixing` skill to Claude Code as an installable plugin.

## Requirements

- **Bash 4+** — macOS ships 3.2; install via `brew install bash`
- **`jq`** — JSON manipulation
- **Node.js 20+** — runs the MCP server (`mcp/server.js`)
- **Claude Code v2.1.87+** — hooks, MCP, agents, slash commands

## Install

```
/plugin install <git-url-of-atelier-cc>
```

After install, `/atelier` becomes available as a slash command.

## Usage

- `/atelier "build oauth"` — start a new pipeline. Asks for pipeline type and worktree choice, then dispatches.
- `/atelier resume <task-description>` — resume an idle pipeline (fuzzy matches against the original prompt).
- `/atelier restart from <stage>` — re-dispatch a specific stage.
- `/atelier status` — list all pipelines with status.
- `/atelier abort` — stop the active pipeline.
- `/atelier <guidance>` mid-stage — redirect a running autonomous subagent (Path A: SendMessage, Path B: re-dispatch with USER REDIRECT block).

## Pipeline Types

| Topology | Stages | Use case |
|----------|-------:|----------|
| `plan`   | 3 | Quick brainstorm → plan → gate (no implementation) |
| `task`   | 8 | Single-task: brainstorm → plan → implement → review → simplify → validate |
| `feature`| 16 | Full feature across 8 phases (spec → conventions → plan → implement → review → simplify → e2e → validate), with `compile_*` preludes and `review_*` counterparts. |
| `epic`   | 8 | Multi-feature initiative: spec + roadmap |

Custom topologies: drop a `<name>.json` into `<workspace>/.atelier/topologies/`. Project overrides shadow plugin defaults by name.

## Architecture

```
atelier-cc/
├── .claude-plugin/plugin.json    — manifest (declares MCP server only; everything else auto-discovers)
├── commands/atelier.md           — /atelier slash command body
├── agents/atelier-stage-worker.md — generic autonomous-stage worker
├── skills/                       — byte-mirrored from ../atelier/skills/
├── topologies/{plan,task,feature,epic}.json
├── hooks/                        — Stop, SubagentStop, PreToolUse(Agent), SessionStart
├── mcp/server.js                 — atelier_signal MCP tool
├── scripts/                      — start-pipeline, resume, restart-stage, abort, compile-prompt, sync-skills, list-topologies, redirect
├── lib/                          — common.sh, pipeline-state.sh, topology.sh, routing.sh
└── tests/                        — unit, integration, regression
```

Three Claude Code hooks plus one MCP tool drive every pipeline:
- **Stop** — routes to the next stage based on `lastVerdict` + topology + `fixAttempts`.
- **PreToolUse(Agent)** — rewrites Agent dispatches to use `atelier-stage-worker` + compiled prompt.
- **SubagentStop** — closes the loop: marks stuck if the subagent didn't signal.
- **SessionStart** — crash recovery (running/stuck → idle, surface idle pipelines in additionalContext).

All routing logic is bash + `jq` against the on-disk `pipeline-state.json`. No LLM decisions.

## Cross-compatibility with Atelier standalone

Three concrete artifacts are shared:

1. **`pipeline-state.json` shape** — plugin writes the exact `PipelineStateData` Atelier expects, plus additive optional fields (`expectedSubagent`, `expectedSkill`, `pendingRedirect`) that survive Atelier's round-trip via `structuredClone`.
2. **Skill content** — `scripts/sync-skills.sh` mirrors `../atelier/skills/*/SKILL.md` byte-for-byte. The pre-commit hook in `atelier-monorepo/` rejects drift.
3. **`atelier_signal` tool schema** — strict superset of Atelier's deployed tool. Plugin accepts custom `pipelineType` strings; Atelier's deployed tool's zod schema is stricter. State-file `state.type` round-trips bidirectionally.

## Development

```bash
git submodule update --init                           # fetch vendored bats-core
tests/bats/bin/bats tests/unit tests/integration tests/regression
cd mcp && npm install && npx vitest run               # MCP server tests
```

From the monorepo root: `bun run test:plugin`.

### Contributing

- Skill changes go in `../atelier/skills/`, not here. Run `bash scripts/sync-skills.sh` to mirror.
- Install the monorepo pre-commit hook: `bash ../tools/install-pre-commit.sh`.
- Tests use Strobe (`debug_test` with `framework: "bats"`) when available; otherwise plain `bats`.

## Multi-session safety (v1.1 — landed)

Multiple Claude Code sessions can run in parallel — same workspace (each session drives its own pipeline) or different workspaces (full isolation). State mutations protect via per-file `mkdir` lockfiles; pipeline ownership tracks via `sourceSessionId` (stamped from `$CLAUDE_SESSION_ID` on start/resume/restart); signals carry explicit `pipelineId`. Crash recovery is heartbeat-driven (`lastHeartbeatMs`, default stale threshold 120s).

**Contract:** one pipeline per session. Run multiple pipelines in parallel by opening multiple CC sessions.

## Known v1 gaps

- **Per-stage model fallback** — `expectedModel` propagates if set; the "fall back to session default + write a note to progress.md" UX is deferred to v1.1.
- **Context economy measurement** — manual exercise in v1; v1.1 adds `tools/measure-context.sh`.
- **Path A (SendMessage) verification** — redirect protocol falls back to Path B (re-dispatch) until Strobe-verified.

## License

MIT
