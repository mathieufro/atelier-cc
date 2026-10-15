# atelier-cc

A Claude Code plugin that runs software work as one flow with dynamic depth. You describe
the task; a strong orchestrator walks the same seven phases every time, at the depth the
task warrants:

```
frame → brainstorm → spec → review → execute → validate → handoff
```

A one-line fix walks it in three short steps. An epic climbs it fully: a multipart spec, a
roadmap, per-phase plans written when each phase starts, waves of delegated tasks verified
by a fresh skeptic per batch, gestalt gates, proof boards the owner judges last, and a
literal completion promise. The rung on the ladder (R0 trivial to R4 epic) is picked at
Frame from five signals and re-checked at every phase boundary.

Design note: [docs/design.md](docs/design.md). Guideline: [docs/precepts.md](docs/precepts.md).
Migration from the previous pipeline types: [docs/migration.md](docs/migration.md).

## Requirements

- Bash 4+ (`brew install bash` on macOS), `jq`
- Claude Code with hooks and slash commands
- Python 3 for the board generator; `sips` and `ffmpeg` when boards carry images or audio
- The `gestalt` plugin for walks on user-visible surfaces (optional; Validate calls it)

## Install

```
/plugin marketplace add mathieufro/atelier-cc
/plugin install atelier@atelier
```

## Use

- `/atelier "<task>"` starts a run. Frame writes a brief with the rung and a budget; Brainstorm
  is a normal conversation, one question per turn, always with a recommendation; everything
  after the approved spec runs unattended.
- `/atelier resume <id>` continues an idle or failed run, `/atelier status` lists this
  workspace's runs, `/atelier abort <id>` stops one. One running run per session.
- Artifacts land in `.atelier/pipelines/<id>/`: `brief.md`, `spec.md`, `plan.md`,
  `reviews/`, `LOOP-BRIEF.md`, `PROGRESS.md`, `gates/`, `board/`, `validation.md`,
  `handoff.md`.

## What keeps a long run honest

- **Stop hook**: no yield mid-autonomous execution, no premature complete (the terminal phase
  is `handoff`), a stale fan-out wait is flagged.
- **PostToolUse heartbeat**: task and ledger re-shown every dozen tool calls.
- **SessionStart**: re-grounding after compaction or resume.
- **Ask-guard**: user questions are denied outside Brainstorm; a decision only the owner can
  make becomes a gate file and the run continues around it.

All four read `state.json` (id, rung, phase, plan, done, status, awaiting) and never write it.

## Host contract

An app that runs Atelier sessions for its owner (Liaison, for one) can set five environment
variables. Frame echoes them, and `commands/atelier.md` §0b and §4 say what each changes.
With none set, Atelier reads and behaves exactly as in plain Claude Code.

| Variable | Effect |
|-|-|
| `ATELIER_AUTONOMY=autonomous` | Brainstorm is one line with its assumptions in `brief.md`; no question, `awaiting` never `"user"` except a genuine blocker; the ask-guard denies every `AskUserQuestion` |
| `ATELIER_HOST=liaison` | `Workflow`, `Monitor`, `SendMessage`, `TaskStop` unavailable: fan-outs are in-turn `Agent` calls, at most 4 at once |
| `ATELIER_HOST_NEEDS_YOU_TOOL` | the tool a genuine blocker, or a failed push or PR, is reported through |
| `ATELIER_HOST_FINISH` | `pr`, `commit` or `none`: Handoff runs the repository's checks, commits on a branch of its own (never `.atelier/`), pushes and opens the PR |
| `ATELIER_HOST_DONE_TOOL` | the tool Handoff calls at the end, with `summary` and `prUrl` |

In host mode `state.json` also carries `boards: [{title, url}]` for the published boards.

0.4.0: host contract (the five variables above). With none of them set, every hook and the command file behave as in 0.3.0.

Release note: `plugin.json` carries `version`, which is the key `claude plugin update` compares. Bump it (and `marketplace.json`) with every change on `main` that should reach installed copies.

## Layout

```
commands/atelier.md      the driver: invariants, Frame, the drive table, finish
skills/                  brainstorming · speccing · reviewing · executing · validating · boards
docs/                    design.md · precepts.md · migration.md
scripts/proof-board.py   builds an owner-facing board from a catalog and proof records
hooks/, lib/common.sh    the four hooks and their shared primitives
tests/unit/*.bats        hook tests (bats tests/unit)
```

## Development

```bash
bats tests/unit          # or tests/bats/bin/bats after git submodule update --init
```

CI runs the suite on Linux and macOS, with and without the autonomous-host environment set.

## Related

- [atelier](https://github.com/mathieufro/atelier): the VS Code version, with its own server and multi-backend support.
- [strobe](https://github.com/mathieufro/strobe): the runtime debugger Execute and Validate lean on for evidence.
- [gestalt](https://github.com/mathieufro/gestalt): the walk Validate calls on user-visible surfaces.

## License

MIT
