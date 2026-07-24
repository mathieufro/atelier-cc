---
name: executing-workstreams
description: "Autonomous execution of one roadmap phase: dispatch each blueprint task to a subagent, verify adversarially, land it, and write the ledger — surviving compaction by keeping nothing important in your own context."
stage: ws_*
---

# Executing workstreams

You are executing **one roadmap phase** of an `autonomous-epic`. The phase has a blueprint
(`blueprints/P<n>-<slug>.md`) holding 25–40 tasks. Your job is to land every task, close the
phase, and record the whole thing durably enough that a compacted successor can pick up
mid-phase without re-deriving anything.

There is **no user**. You never ask; you decide and keep going.

## The shape of this stage — read this first

A `ws_` stage is **one long turn punctuated by auto-compaction**. There is no external loop
driver and you do not need one: the Stop hook keeps you driving, and when the context fills,
compaction takes it. That has one consequence that governs everything below.

**You will be compacted mid-phase, without warning, and you will not know what you lost.**

Two disciplines follow, and they are the whole skill:

1. **You are a dispatcher, not an implementer.** The work happens in subagent contexts, not
   yours. Your per-task context cost is one task spec out, one result summary back, one
   verdict — never an implementation. This is what makes 40 tasks fit in one stage.
2. **Write the ledger before you would need it, never after.** Anything that exists only in
   your context is one compaction from gone, and the loss is silent.

## Ground first

Read, in this order, every time you enter this stage — including after a compaction:

1. **`impl/PROGRESS.md`** — the ledger. It tells you where you are. Read it FIRST, always,
   before forming any plan.
2. **`impl/LOOP-BRIEF.md`** — the static operating rules for this epic (branch names, build
   commands, box quirks). Short and unchanging.
3. **`blueprints/grounding-facts.md`** — verified integration facts.
4. **Only the current task** from your phase blueprint. Use `offset`/`limit`. Do not read
   the whole blueprint and do not hold it in context; it is 40–60 KB and you will need the
   room.

The spec is the contract. The blueprint is the plan. The ledger is the truth about progress.

## The ledger

`impl/PROGRESS.md` is not a diary. It is the state a successor needs, and nothing else:

| Section | What it holds | Why a successor dies without it |
|---|---|---|
| **Cursor** | current phase, current task, what is next | Otherwise you re-do or skip work |
| **Task rows** | id · status · commit SHA · one-line note | The SHA is how you prove a task landed |
| **Known-failure baseline** | the named failures inherited at `ws_baseline`, each diagnosed | Without it you cannot answer *"is this failure new or pre-existing?"* — so you either chase inherited breakage for hours or wave a real regression through |
| **Coordination notes** | edits made outside a task's declared file allowlist | The next task's agent needs to know the ground moved |
| **Deviations** | where the implementation departed from the blueprint, and why | These batch into spec Amendments at phase close |
| **Box notes** | exact build/test commands, tool gaps, platform traps | Hours to rediscover, one line to record |

Box notes are the section most often skipped and most expensive to lose. When you learn that
a preset deadlocks, that a suite must be run in chunks, that a discovery mode has to be
forced — write it down the moment you learn it.

Update the ledger **at every landing**, not in batches. A batched ledger is an unwritten one.

## One iteration = one task

Repeat until the blueprint is done.

### 1. Pick the task
From the ledger's cursor. One task, or one tightly-coupled group that genuinely cannot be
split. Never "a few tasks to save time" — that is how a compaction eats three tasks' worth
of unrecorded work.

### 2. Dispatch an implementer subagent
Hand it: the task's WHAT/HOW verbatim, the files it may touch, the tests-first requirement
with exact test names, the relevant grounding facts, and the build/test commands from the
ledger's box notes. Instruct it to write tests first, make them pass, and return a
done-signal or a stuck-report.

Do **not** paste the whole blueprint. Do not let it wander outside its file allowlist; if it
must, that is a coordination note.

### 3. Verify adversarially — this is yours, and it is not delegable to the implementer
Never accept a done-signal on its word. A subagent reporting success is evidence, not proof.

Dispatch a **fresh** skeptic subagent — fresh because a verifier that shares the
implementer's context inherits its blind spots — and prompt it to **refute**: run the tests,
read the diff, ask whether the test would actually fail if the feature were absent. A test
that passes against a stubbed implementation has proved nothing.

For anything you can check mechanically, check it mechanically: run the build, run the named
tests, read the actual output. Do not accept a claim you can cheaply verify.

### 4. Fix
Two subagent fix rounds. If it is still broken, take it over yourself — you have more context
about this phase than any fresh worker will.

**Count attempts per TASK, not per stage.** A `ws_` stage holds 40 tasks; two unrelated task
failures say nothing about the phase. Key your counters `attempts["<ws_stage>:<task_id>"]`.
The stage-keyed sonnet→opus and OPUS_CAP ladder in `atelier.md` §6 does **not** apply here —
applying it would escalate or fail an entire 40-task phase over two unrelated hiccups.

### 5. Land
Commit. Tick the blueprint checkbox with the SHA. **Write the ledger.** Then next task.

Commit per task, not per phase. A phase-sized commit is unreviewable and unrevertable, and
it loses the per-task SHA the ledger depends on.

## Phase close

When the last task lands, close the phase. Run the applicable steps and **record N/A with a
reason for any you skip** — a phase legitimately has no gate artifacts if it has no gates.
Do not tick a step you did not run.

1. **Ledger check** — every task row has a status and a SHA.
2. **Blueprint validation commands** — run them **verbatim**, not paraphrased.
3. **Phase E2E** — green against the real application, not a harness that proves itself.
4. **Gestalt pass** — on the whole-phase diff, per `gestalt-qa`.
5. **Simplification pass** — one, per `simplifying-implementation`.
6. **Gate artifacts** — prepared for any human gate this phase owes.
7. **Deviations → spec Amendments** — batch this phase's deviations into one amendment entry.
8. **Full suite** — green *relative to the known-failure baseline*, then push.

Only then does the stage enter `done[]`.

## Hard rules

These come from real incidents. They are cheap to honour and expensive to relearn.

- **Verify the branch in the same command as the commit.** Not before, not in a previous
  call — in the same shell invocation:
  `[ "$(git branch --show-current)" = <branch> ] && git commit …`. Two accidental pushes to
  a shared branch happened before this rule existed. In a submodule tree, check every
  submodule you touch.
- **One build at a time**, across you and every subagent. Concurrent builds on one tree
  corrupt each other. If you need a mechanism rather than a convention, take a lock file and
  record its path in the ledger; state a staleness rule so a crashed build cannot wedge the
  phase forever.
- **Builds and tests run in the FOREGROUND** with a generous timeout. A backgrounded build
  plus a Stop hook produces useless wake-ups. If a foreground build times out, run it again —
  it resumes incrementally.
- **Never claim a test result you did not see.** Paste the actual counts. "Should pass" is
  not a result.
- **A flaky test is not a fix.** If it passes on re-run with no code change, record it as
  flaky in the ledger. Do not report it as resolved.
- **Do not fix unrelated breakage you stumble on.** Record it as a coordination note or a
  deviation and keep going. Scope creep inside an autonomous loop is unbounded.

## Context etiquette

You are the scarcest resource in this stage. Protect yourself:

- Read blueprints with `offset`/`limit`, around the active task only.
- Never hold a whole blueprint, a whole spec, or a large diff in context.
- Use `TodoWrite` as intra-iteration scratch, not as the ledger. It does not survive
  compaction; `PROGRESS.md` does.
- Summarize subagent results down to the verdict and the SHA. Do not keep their transcripts.

## After a compaction

You will not notice it happened. That is fine, because the procedure is the same as entering
the stage: read `impl/PROGRESS.md` first, then `LOOP-BRIEF.md`, then the current task. The
cursor tells you where you are. If the ledger and the git log disagree, **git is the truth** —
reconcile the ledger to it before doing anything else, and note the reconciliation.

If a stage's output artifacts already exist on disk, **reconcile with them; do not re-run the
work that produced them.**

## Returning

End your turn with the phase result as your final message:

- `PHASE COMPLETE — P<n> <slug>, <n>/<n> tasks landed, close steps <list> (N/A: <list>), suite <counts> vs baseline, pushed <sha>`
- If you cannot proceed: `{stuck:true, stage:"<ws_stage>", attempted:[…], blocker, lastError, partialArtifacts:{progress:"impl/PROGRESS.md"}}`

The orchestrator reads your final message and updates `state.json`.
