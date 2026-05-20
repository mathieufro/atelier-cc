# atelier-cc

Claude Code plugin port of [Atelier](https://github.com/mathieufro/atelier) — an autonomous, multi-stage software-development pipeline.

You describe what you want. Atelier takes it through brainstorming, spec, planning, implementation, **independent review**, simplification, and testing — specialized agents that review each other's work and fix issues *before* delivery. It is not a chatbot loop; it is an orchestrator that turns a one-shot agent into a disciplined engineering process.

## Requirements

- **Bash 4+** — macOS ships 3.2; install via `brew install bash`
- **`jq`** — JSON manipulation
- **Node.js 20+** — runs the MCP server (`mcp/server.js`)
- **Claude Code v2.1.87+** — hooks, MCP, agents, slash commands
- **Strobe** (recommended) — LLM-native runtime debugger used by the implement, bugfix, and e2e stages for test-driven verification. Configure in `.mcp.json`.

## Install

```
/plugin install https://github.com/mathieufro/atelier-cc.git
```

This pulls the whole plugin in one go — all 29 skills, slash commands, agents, hooks, and the bundled MCP server. After install, `/atelier` is available as a slash command.

## Quick start

```
/atelier "add SAML SSO to the auth service"
```

Atelier asks two questions — **pipeline type** (it recommends one; you confirm) and **in-tree vs worktree** — then runs. Interactive stages (brainstorm/plan) are a normal conversation: the agent leads with a recommendation + rationale and one question at a time; you answer in chat. Autonomous stages run unattended. Artifacts land in `.atelier/pipelines/<id>/`; with git integration on, each stage transition is its own commit so you can review or roll back stage-by-stage.

You can walk away during autonomous stages and come back. If a stage runs out of context it writes `progress.md` and resumes from there; if it escalates, `/atelier resume <desc>` continues it.

## Choosing a pipeline

This is the main decision. The classifier recommends one from your prompt, but knowing the model helps you prompt well. **When in doubt, Feature is the workhorse.**

| Pipeline | Reach for it when | Deliverable |
|----------|-------------------|-------------|
| **Quick Plan** | You roughly know what you want and just need a vetted plan fast — an architectural change, a refactor strategy, a dependency upgrade, scoping a fix. Optionally gate straight into implementation. | A reviewed plan (then optionally: the implementation) |
| **Bugfix** | An error report, stack trace, failing test, or regression. The bug description *is* the input — no brainstorm. | A root-caused fix + diagnostic write-up |
| **Task** | A small, well-defined change touching 1–2 components, holdable in one engineer's head. Combined spec-plan hybrid (no separate brainstorm/plan). | Implemented + reviewed + validated change |
| **Feature** | A single concrete deliverable: one spec, one plan, one implementation pass — a new feature, a cross-component refactor, a medium project that benefits from formal spec→plan separation. | Implemented, reviewed, simplified, e2e-tested, validated feature |
| **Epic** | A large multi-subsystem effort, a new product, or a major rewrite. Produces the **scoping documents**; you then run each phase as its own Feature pipeline. | A main spec + a phased roadmap |

### Composing for autonomous full-app / large feature-set development

`Epic → roadmap → a Feature (or Task) pipeline per phase`. The Epic pipeline does the hard architectural thinking once — a coherent main spec and a dependency-ordered phase breakdown with explicit interface contracts between phases — so each phase is then an independently runnable, well-bounded Feature pipeline. This is how you drive a whole application or a large feature set autonomously without the design fragmenting: the roadmap is the durable contract; each phase pipeline is fresh-context and individually gated.

### What each pipeline actually runs

`compile_*` stages are codebase-orientation preludes — an agent reads the repo and produces a tight, codebase-aware prompt for the stage that follows, so the brainstorm/plan agent starts oriented instead of blind. `review_*` stages are independent fresh-eyes reviewers; a failing review synthesizes a `fix_*` stage (up to a cap) before advancing.

- **Quick Plan** (3): `quick_plan` → `review_quick_plan` → `plan_gate` *(gate: stop with the plan, or proceed to implement)*
- **Task** (8): `compile_task_brainstorm` → `task_brainstorm` → `review_task` → `establish_conventions` → `implement` → `review_code` → `simplify` → `validate`
- **Feature** (16): `compile_brainstorm` → `brainstorm` → `review_spec` → `establish_conventions` → `compile_plan` → `write_plan` → `review_plan` → `implement` → `review_code` → `simplify` → `e2e_gate` → `compile_e2e_plan` → `write_e2e_plan` → `review_e2e_plan` → `e2e` → `validate`
- **Epic** (8): `compile_brainstorm` → `brainstorm` → `review_spec` → `establish_conventions` → `compile_roadmap_brainstorm` → `brainstorm_roadmap` → `review_roadmap` → `validate`

## Why a pipeline instead of one-shot agentic coding

A single agent told to "build X" fails in predictable ways on non-trivial work: it conflates discovery with commitment, writes code before the design is settled, confirmation-biases its own review, drifts as the context window fills, and reports success it never verified. Atelier is structured specifically to defeat each of those:

- **Fresh-eyes review.** Every artifact (spec, plan, code, e2e plan) is reviewed by an agent with **zero context** from the agent that produced it. No author waves through its own work; a reviewer that finds issues triggers an in-loop fixer (capped attempts), then re-review. Quality gating happens *before* delivery, not after you hit the bug.
- **Test-driven by construction.** Planning produces a TDD task breakdown; implementation runs the tests as it goes and uses Strobe for runtime evidence rather than guessing. The plan's tasks *are* the spec made executable — "done" means a green suite, not an agent's say-so.
- **E2E for behavior LLMs can't see.** An `e2e_gate` decides whether user-facing behavior needs end-to-end coverage; if so, e2e plans and runs real journey tests with runtime observability. Unit tests prove functions; e2e proves the thing actually works — the gap where LLM-written code most often silently fails.
- **Discovery is separated from commitment.** Brainstorm is a real conversation that produces a spec; the spec is reviewed; only then does planning start. The agent can't jump straight to code on a half-understood problem because the topology won't let it.
- **Context economy.** Each stage runs in a fresh context with exactly the prior artifacts it needs (the `compile_*` preludes do the orientation). Quality doesn't decay over a long build the way a single ballooning conversation does. Long stages checkpoint to `progress.md` and resume.
- **Deterministic orchestration.** Routing is bash + `jq` over an on-disk state file — *no LLM decides control flow*. The pipeline cannot hallucinate its own next step, loop, or quietly abandon the task. Stuck/escalation states are explicit and resumable.
- **Conventions before code.** On greenfield/under-specified projects, `establish_conventions` researches and codifies stack conventions first, so the implementation is consistent instead of improvised per-file.

The net effect: work you can leave running and trust the gates on, instead of work you have to babysit and re-review yourself.

## Usage

- `/atelier "<task>"` — start a new pipeline (asks pipeline type + worktree, then dispatches).
- `/atelier resume <task-description>` — resume an idle/escalated pipeline (fuzzy-matches the original prompt; clears a terminal verdict so it actually re-dispatches).
- `/atelier restart from <stage>` — re-run from a specific stage.
- `/atelier status` — list pipelines with status.
- `/atelier abort` — stop the active pipeline.
- `/atelier <guidance>` mid-stage — inject a course-correction; applied at the next stage boundary (`pendingRedirect`).

**One pipeline per Claude Code session.** Run several in parallel by opening several sessions — same workspace (each drives its own) or different workspaces (full isolation).

## Advanced: custom pipelines & skills

Most users never need this — the four built-in pipelines plus Bugfix cover normal development. Reach for custom topologies only for *repeatable non-coding workflows* (e.g. a bookkeeping or data pipeline you run every month).

- **Custom topology:** drop `<name>.json` into `<workspace>/.atelier/topologies/`. A project topology shadows a plugin default of the same name.
- **Custom skills:** `$HOME/.atelier/skills/<name>/SKILL.md` (YAML frontmatter `name`/`description` + Markdown instructions). User skills win over plugin-bundled skills of the same name and can be referenced from any custom topology.
- **Guided authoring:** `/atelier pipeline create` walks you through design and emits a self-installing script.

A worked example (a French-bookkeeping topology composing five custom skills) lives at `tests/fixtures/accounting-pipeline/`:

```
cp -R tests/fixtures/accounting-pipeline/skills/* ~/.atelier/skills/   # ⚠ overwrites same-named skills
mkdir -p .atelier/topologies && cp tests/fixtures/accounting-pipeline/accounting.json .atelier/topologies/
/atelier "process March invoices"   # pick `accounting` when prompted
```

## Architecture

```
atelier-cc/
├── .claude-plugin/plugin.json    — manifest (declares the MCP server; everything else auto-discovers)
├── commands/atelier.md           — /atelier slash command body
├── agents/atelier-stage-worker.md — generic autonomous-stage worker
├── skills/                       — byte-mirrored from ../atelier/skills/
├── topologies/{plan,task,feature,epic}.json
├── hooks/                        — Stop, SubagentStop, PreToolUse(Agent), PostToolUse(atelier_signal), SessionStart
├── mcp/server.js                 — atelier_signal MCP tool
├── scripts/                      — start-pipeline, resume, restart-stage, abort, compile-prompt, sync-skills, …
├── lib/                          — common.sh, pipeline-state.sh, topology.sh, routing.sh, dispatch.sh
└── tests/                        — unit, integration, regression
```

Hooks + one MCP tool drive every pipeline; all routing is bash + `jq` against `pipeline-state.json` (no LLM decisions):

- **`atelier_signal` (MCP)** — a stage worker calls this to record its verdict + artifact, then ends its turn.
- **PostToolUse(atelier_signal)** — advances the pipeline the instant a *main-agent* (interactive) stage signals; no-ops inside subagents.
- **SubagentStop** — advances when a stage-worker subagent finishes (autonomous *and* interactive-via-subagent), keyed off the recorded verdict.
- **Stop** — advances main-agent boundaries; stays silent while an interactive stage is mid-conversation so the agent can yield to the user; ghost-recovers wedged autonomous dispatches.
- **PreToolUse(Agent)** — rewrites autonomous dispatches to the compiled stage prompt; *blocks* delegating an interactive stage to a subagent (interactive stages are led by the main agent).
- **SessionStart** — heartbeat crash-recovery; surfaces idle pipelines.

## Cross-compatibility with Atelier standalone

1. **`pipeline-state.json` shape** — the plugin writes the exact `PipelineStateData` Atelier expects, plus additive optional fields that survive Atelier's `structuredClone` round-trip.
2. **Skill content** — `scripts/sync-skills.sh` mirrors `../atelier/skills/*/SKILL.md` byte-for-byte (atelier-cc-native skills like `create-pipeline` are preserved); the monorepo pre-commit hook rejects drift.
3. **`atelier_signal` schema** — a strict superset of Atelier's deployed tool; `state.type` round-trips bidirectionally.

## Development

```bash
git submodule update --init                           # vendored bats-core
tests/bats/bin/bats tests/unit tests/integration tests/regression
cd mcp && npm install && npx vitest run               # MCP server tests
```

- Skill changes go in `../atelier/skills/`, then `bash scripts/sync-skills.sh` to mirror.
- Install the monorepo pre-commit hook: `bash ../tools/install-pre-commit.sh`.

## Known v1 gaps

- **Per-stage model fallback** — `expectedModel` propagates if set; the "fall back to session default + note in progress.md" UX is deferred.
- **Path A (SendMessage) redirect** — the redirect protocol falls back to re-dispatch (Path B) until Strobe-verified.

## License

MIT
