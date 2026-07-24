---
name: writing-blueprints
description: "Expand an approved roadmap into per-phase executable blueprints at execution depth — one file per phase, 25-40 tasks each, every task dispatchable to a subagent with no further design work."
stage: write_blueprints
---

# Writing blueprints

You are turning an approved roadmap into the artifacts an autonomous loop will execute. A
roadmap phase says *what this phase proves*. A blueprint says *exactly what to do, in what
order, and how each step is proven* — at a depth where an implementer subagent needs no
design judgment at all.

The test of a blueprint is blunt: **could a competent subagent, handed one task and nothing
else, do it correctly?** If it would have to infer intent, guess a signature, or go read the
spec to find out what "wire it up" means, the task is not written yet.

## Order of work

The prologue is **serial and yours**. The per-phase authoring is a **fan-out**. Do not start
the fan-out before the prologue exists — every author depends on it.

### Prologue 1 — `blueprints/README.md`

The authoring standard the fan-out follows: the task template below, the naming scheme, how
files are allocated to phases, and the depth target. Short. It exists so seven authors write
one document rather than seven.

### Prologue 2 — `blueprints/grounding-facts.md`

The single highest-leverage artifact in the stage. Verified integration facts hoisted out of
individual blueprints so that seven authors cannot each invent a different version of the
same truth.

- **Facts only. No recommendations, no design.** If it is a judgment, it belongs in a
  blueprint or the spec.
- **`file:line` for every claim.** A fact without a citation is a guess.
- **Stamp it** with tree, branch, and date. It is a snapshot and it will go stale.
- Tag the awkward ones explicitly: **GAP** (needed and absent), **HARD BLOCKER** (must be
  resolved before the phase can run), **CAVEAT** (true but easy to misread).
- Include **end-to-end registration checklists** for anything that must be wired in more
  than one place. "Add the type" is where things get half-done; a checklist naming every
  registration site is what prevents it.

**If a fact you verified contradicts the spec, STOP and record it** as a HARD BLOCKER rather
than quietly designing around it. A spec that disagrees with the tree is a spec problem, and
it is far cheaper to surface here than mid-execution.

### Prologue 3 — `blueprints/EXPANSION-PROGRESS.md`

Create it **at the start**, not the end. It is this stage's own ledger and resume cursor:
one row per phase, marked as each blueprint is authored. If you are compacted mid-fan-out,
this is what stops you re-authoring a 50 KB blueprint that already exists. A row marked done
means the file is on disk — reconcile with it, do not regenerate it.

It is also the parking lot for author decisions that need ratifying later.

### Then: one authoring agent per roadmap phase

Each writes `blueprints/P<n>-<slug>.md`. Give each author the spec, the roadmap phase, the
grounding facts, the README standard, and its file allocation.

## Depth

**Target 25–40 tasks for a substantial phase.** This is not a quota — it is the depth at
which tasks stop containing hidden design work. A 6-task blueprint for a real phase is a
roadmap wearing a blueprint's filename, and every one of its tasks will stall an implementer.

A task should be a subagent-sized unit: a coherent change with its own tests, landing in one
commit. If a task needs a paragraph to explain what "done" means, split it.

## The task template

Every task carries all six. No exceptions — a missing field is where autonomy breaks.

- **WHAT** — one sentence, imperative. The outcome, not the activity.
- **HOW** — the approach, concretely: names, signatures, call sites, data shapes. Enough that
  two different agents would produce substantially the same thing.
- **Files it may touch** — an explicit allowlist. This is what makes parallel phases safe and
  what makes an out-of-scope edit visible as a coordination note.
- **Tests first** — exact test names (ASCII only) and the numeric assertions they make. Write
  the names here so the implementer cannot invent a test that cannot fail.
- **Done when** — a mechanically checkable condition. "Works correctly" is not one.
- **Depends on** — task ids within the phase, if any.

State the **negative** where it matters: what this task must NOT change. It is usually
cheaper to name the forbidden edit than to detect it later.

## Every blueprint ends with two mandatory sections

- **E2E** — the end-to-end scenario proving the phase's roadmap goal, run against the real
  application. Not a unit test with a wider scope.
- **Validation** — the literal commands a validator will run, verbatim and copy-pasteable,
  with their expected results. If a command cannot fail, it is not validation; a validation
  step that greps for a string the build always emits proves nothing.

## Phase-owned files and the frozen surface

For each phase, state which files it **owns** (may edit freely), which are **frozen** (must
not change), and which are **append-only** (shared registries, where two phases each add a
row and neither may reorder). The union of all phases' allowlists must not overlap on an
owned file — if two phases own the same file, one of them is mis-scoped, and that is a
finding to fix now rather than a merge conflict to discover later.

Where a later phase needs a seam from an earlier one, the earlier phase creates the **stub**
and the later phase fills it. Say so in both.

## Self-check before you finish

For each blueprint:

- Would a subagent handed task N alone succeed, with no other context?
- Does every task's test actually discriminate — would it fail if the feature were absent?
- Is every exit criterion in the roadmap phase reachable from these tasks?
- Does any task silently require work that no task does?
- Are the validation commands runnable as written?

## Returning

Write all blueprints plus the three prologue artifacts, then end your turn:

- `BLUEPRINTS WRITTEN — <n> phases, <total> tasks (per phase: <counts>), grounding facts <n> claims, <n> GAP / <n> HARD BLOCKER`

If a HARD BLOCKER makes a phase unauthorable, say so plainly and name it rather than writing
a blueprint around a contradiction.
