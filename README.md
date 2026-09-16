# atelier-cc

[Atelier](https://github.com/mathieufro/atelier) as a Claude Code plugin. You describe what you want; one orchestrator takes it through investigation, spec, plan, implementation, independent review, simplification and tests, and only stops to talk to you during design.

It is not a chat loop. It is a disciplined engineering process, run by an agent that is not allowed to bail out.

## Install

```
/plugin marketplace add mathieufro/atelier-cc
/plugin install atelier@atelier
```

Requirements: Claude Code with plugin support, `jq`, and Bash 4 or later (macOS ships 3.2, `brew install bash`). [Strobe](https://github.com/mathieufro/strobe) is recommended: the implement and e2e stages use it for runtime evidence instead of guessing.

## Use

```
/atelier "add SAML SSO to the auth service"
```

The orchestrator confirms the pipeline type and whether to work in a git worktree, then drives. Design stages are a normal conversation, one question at a time, each opening with a recommendation. Everything after design runs unattended. Artifacts land in `.atelier/pipelines/<id>/`.

| Command | What it does |
|---|---|
| `/atelier "<task>"` | Start a pipeline |
| `/atelier resume <id or description>` | Continue an idle or failed pipeline |
| `/atelier status` | List this workspace's pipelines |
| `/atelier abort <id>` | Stop one |

One running pipeline per Claude Code session. Open more sessions to run more.

## Pipelines

| Type | Reach for it when | Stages |
|---|---|---|
| **task** | A bug fix or a small feature you can hold in your head | blueprint (interactive) -> review -> implement -> code review -> validate |
| **feature** | One concrete deliverable that deserves a separate spec and plan | brainstorm (interactive) -> spec review -> plan -> plan review -> implement -> code review -> simplify -> e2e gate -> e2e plan -> e2e review -> e2e -> validate |
| **epic** | A multi-feature initiative you want scoped, not built | brainstorm -> spec review -> roadmap (interactive) -> roadmap review -> validate |
| **autonomous-epic** | The same, then build the whole roadmap without you | research -> brainstorm -> spec -> spec review -> roadmap -> roadmap review -> blueprints -> blueprint review -> execute every phase -> gestalt QA -> validate |

Every speccing stage opens with an investigation of the codebase, so the conversation starts oriented instead of blind. Reviews are fan-outs of fresh-context agents; a review that finds issues triggers one fix pass, then the pipeline moves on. The terminal `validate` stage is the final net.

## What keeps it honest

The orchestrator is a single long-running agent, and long-running agents drift. Four hooks and a small ledger keep it on task:

- **`state.json`** is the per-pipeline ledger: type, stage list, what is done, retry counters, what the orchestrator is waiting on. The orchestrator is its only writer.
- **Stop hook.** While a pipeline is running and not waiting on you, the orchestrator is not allowed to end its turn. It also refuses a premature "complete": the pipeline is done only when its terminal stage is done.
- **AskUserQuestion guard.** During autonomous execution, asking the user is hard-denied. The orchestrator takes the sensible default and keeps driving; `failed` is reserved for a genuine blocker such as a missing credential.
- **PostToolUse heartbeat.** Every dozen or so tool calls, the task and the remaining stages are re-shown from the ledger, not from the agent's decaying memory.
- **SessionStart re-grounding.** After compaction or a resume, the orchestrator is re-anchored on the ledger before it does anything.

Credentials, accounts and deploy targets are collected during speccing, in the spec's prerequisites section, so the autonomous half never has to stop for them.

## Layout

```
atelier-cc/
  .claude-plugin/      plugin and marketplace manifests
  commands/atelier.md  the orchestrator: classification, drive loop, flows, model allocation
  skills/              18 stage skills (brainstorming, planning, reviewing, implementing, e2e, gestalt QA, ...)
  hooks/               stop, ask-guard, post-tool-use, session-start
  lib/common.sh        shared shell helpers
  tests/               bats unit tests for the hooks
```

Skills are byte-mirrored from the Atelier repository; the two projects share one methodology.

## Development

```bash
git submodule update --init          # vendored bats-core
tests/bats/bin/bats tests/unit
```

## Related

- [atelier](https://github.com/mathieufro/atelier): the VS Code version, with its own server and multi-backend support.
- [strobe](https://github.com/mathieufro/strobe): the runtime debugger the implement and e2e stages rely on.

## License

MIT
