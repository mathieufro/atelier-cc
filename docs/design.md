# Atelier: one flow, dynamic depth

Design note for the 2026-09 rewrite. Short on purpose: the flow is the same every time, the
ladder decides how deep each phase goes, and the precepts in `docs/precepts.md` are a
development guideline for a strong model, not a script it must follow.

## Why

The plugin was written for a weaker model: four pipeline types, a 12-stage feature flow, a
`features` object, compile preludes, dossier objects, a fixed review fan-out per stage,
blueprints for every phase up front. The runs that actually shipped in 2026 did not follow it.
Fine-line's DSP epic and the polytimbral epic both dropped the fixed stages after the spec and
ran on a loop brief plus a progress ledger; the September task runs marked stages done that
never produced an artifact; the overnight retrospective named "review sized for a Feature,
applied to a Task" as the waste. What did pay for itself is a short list: brainstorming with
the owner, a spec that is a contract, fresh-eyes review of documents, a fresh opus skeptic per
batch of landings, validation through the real surface with evidence, published proof boards
the owner judges last, fix-review loops with evidence, and the ledger-driven hooks that keep a
run driving through compaction. That list is the flow.

## The flow

Seven phases, always in this order. A phase can be one line deep; it is never absent.

| Phase | Produces | What it is for |
|---|---|---|
| **Frame** | `brief.md`, `state.json` | Read the task and the repo once. Pick the rung. Estimate the budget. Write what done means. |
| **Brainstorm** | decisions in `brief.md` or `decisions.md`, prototypes, a decision board | Settle the design with the owner. One question at a time, a recommendation each time. The last chance to ask anything. |
| **Spec** | `spec.md` (+ satellites), `plan.md` or `plans/P<n>.md`, `roadmap.md` | The contract: numbered success criteria, validation protocol, prerequisites, then the task-depth plan. |
| **Review** | `reviews/<artifact>-<n>.md`, a fix ledger | Fresh eyes on the spec and plan before code exists. One pass, one fix, no re-review. |
| **Execute** | `LOOP-BRIEF.md`, `PROGRESS.md`, commits | Test-first, one task per iteration, verified by a fresh skeptic per batch, landed with its SHA in the ledger. |
| **Validate** | `validation.md`, `board/`, gestalt run docs | Automated first: the protocol, e2e through the real surface, a gestalt walk where surfaces changed, a proof board with evidence per claim. The owner checks last. |
| **Handoff** | `handoff.md` | What was built, what is proven, what remains unverified, what to try first. Under ten lines. |

Every phase reads the phase before it and writes one place. Nothing is journalled into
`state.json`; the ledger is `PROGRESS.md`, and where the ledger and git disagree, git wins.

## The ladder

Five rungs. The rung is chosen at Frame from five signals and re-checked at every phase
boundary; a task climbs when a signal changes, and the climb is recorded in the ledger.

| Signal | R0 trivial | R1 small | R2 feature | R3 wide | R4 epic |
|---|---|---|---|---|---|
| Subsystems touched | one file, known cause | one | two, or one with a new surface | any | three or more |
| Unknowns | none | a local choice | a design conversation | many independent facts to gather | open research questions |
| User-visible surface | none | none or unchanged | yes | any | many |
| Fits one context with delegation | yes | yes | yes | yes, with sweeps | no |
| Width (independent reads feeding one small answer) | no | no | no | yes | usually |

What each rung does per phase:

- **R0**: Frame, Execute, Validate, in three short steps. Brainstorm is one confirming line
  only if intent is ambiguous. No review. Validation is the test that fails without the fix
  plus whatever check the change implies. Handoff is three lines.
- **R1**: a ten-line brief stands in for the spec. Self-skeptic on the diff (mutation check);
  one fresh opus skeptic if the change touches a risk area. Validation from the brief's checks.
- **R2**: a real brainstorm; a spec with success criteria, validation protocol and
  prerequisites; a plan in the wave-spec shape; fresh-eyes review of the spec with one to three
  lenses, opus on the risky one; a skeptic per batch of landings; validation through the real
  surface and a proof board when the surface is user-visible.
- **R3**: R2 plus cheap-model sweeps wherever many independent reads feed one small answer
  (research surveys, datasheets, API or web scraping, codebase-wide audits, corpus checks, a
  validation pass over a large surface). Sweeps run on haiku or sonnet with a fixed answer
  schema; synthesis and judgement stay on the orchestrator's model.
- **R4**: multipart spec with an append-only decisions log and a roadmap whose phases are the
  durable contract; a task-depth plan written per phase when that phase starts, grounded in
  the tree at that commit, never for all phases up front; loop brief and ledger; waves of
  independent tasks; batch skeptics; a phase close with a gestalt gate where surfaces changed;
  owner gates queued in files, never blocking; a proof board per phase; a literal completion
  promise as the stop condition.

Token awareness: Frame writes a budget estimate in the brief. When the actual spend passes
twice the estimate, the orchestrator stops, re-frames (climb a rung or cut scope) and records
it. Verification sits well under a third of implementation time; a review pass returning only
low findings closes the batch.

## Where artifacts enter

- **Brainstorm board** (R2 with UI, R4 always): a published page of decision cards, each
  with options and a recommendation, or a pixel-faithful prototype. The owner clicks; the
  choice is read back from the artifact database into `decisions.md`. Approved prototypes are
  pinned by URL in the spec.
- **Proof board** (Validate, R2 and above when the surface is user-visible; always at R4): one
  card per check item, my verdict frozen in the page with evidence (screenshot, audio, log),
  the owner's verdict written live into the database as ok, issue or skip plus a note. Rounds
  of fix, redeploy, republish until every card carries an owner verdict; what is left is listed
  as open.
- **Gate files** (`gates/<id>.md`): question, options with a recommendation, evidence, artifact
  URL, then VERDICT and SIGNED lines that only the owner writes. A gate never blocks the loop;
  work continues on everything it does not gate.
- **Evidence**: filed by area under `board/proof/<item>/`, referenced from the ledger by
  path. Method labels are binding: measured, analytic, not measured.

The board generator ships in `scripts/proof-board.py`; the `boards` skill is the mechanism.

## Where cheap-model workflows run

Triggers: any sweep where many independent reads feed one small answer; any validation pass
that must cover a large surface; any epic whose size exceeds one context even with delegation.
The ladder decides per task, never a fixed rule per pipeline type. Sweep agents run on haiku
(reads, greps, table filling) or sonnet (a sweep needing judgement per item); the Workflow tool
is used above roughly six agents or when a pipeline of sweep then verify is wanted; below that,
Agent calls launched in one message. Every call names its model. Depth never exceeds two.

## Ledger and hooks

`state.json` keeps what the hooks need and nothing else: `id`, `task`, `rung`, `phase`,
`plan` (the seven phases), `done[]`, `status`, `awaiting`, `sourceSessionId`,
`workspaceRoot`, `worktree`, `budget`, `updatedAt`. It is written at phase boundaries only.
The four hooks are unchanged in role and re-keyed on the phases: Stop blocks a yield
mid-autonomous execution and a premature complete (terminal phase is `handoff`); the
PostToolUse heartbeat re-shows task and ledger on a cadence; SessionStart re-grounds after
compaction; the ask-guard denies user questions outside Brainstorm. The stale-workflow window
scales with the rung.

## Deleted, and why

- Pipeline types and the 12-stage feature flow: one flow with a ladder replaces them.
- The `features` object and `autonomous-epic` plan expansion: waves live in the ledger.
- Compile preludes and the required `dossier.json`: grounding notes live in the brief.
- Up-front blueprints for every phase and their 25-agent review: stale by phase two in
  fine-line; the per-phase plan is written when the phase starts.
- `e2e_gate`, `write_e2e_plan`, `review_e2e_plan`, `e2e` as stages: e2e is a validation
  activity through the real surface, decided by the rung.
- `simplify` as a stage: a phase-close step at R2 and above.
- `gestalt-qa` as a skill: the gestalt plugin owns the walk; Validate calls it and keeps the
  gate rules.
- The per-stage retry ladder and step budget: replaced by the verification budget and two
  fix rounds per task, then the orchestrator takes it over.
- 18 skills folded into 6: brainstorming, speccing, reviewing, executing, validating, boards.

## Kept, and where it came from

Brainstorm rules and the verification sweep (feature and epic brainstorming skills). The spec
as an executable contract with amendments (speccing-epic-multipart). Fresh-eyes lenses and the
severity reduction (reviewing). Fix ledgers with a disposition per finding (fine-line).
Loop brief, ledger sections, hard rules and phase close (executing-workstreams, polytimbral).
Batch skeptic, verification budget, long-running rules, delegation rule (fine-line and
erae CLAUDE.md). Gate files with VERDICT and SIGNED (fine-line waveguide). Proof board with
two verdict layers (polytimbral QA, Liaison tour). Gestalt gate rules: charters at spec time,
BLOCK or ADVANCE, goldens blessed only from judged frames (gestalt-qa).
