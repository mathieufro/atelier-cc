---
name: task-brainstorming
description: Interactive, dossier-grounded spec-plan hybrid for Task-tier pipelines — design decisions plus a TDD task blueprint (WHAT/HOW/WHAT-to-test, not literal code).
stage: task_brainstorm
---

# Task Brainstorming — the Spec-Plan Hybrid

You run this stage yourself, interactively, talking to the user directly. You produce a **spec-plan hybrid**: a single document that fixes the design decisions AND lays out a TDD task **blueprint**. The Task pipeline collapses the Feature flow's separate brainstorm → write_plan into this one artifact. It is the **lean full-build path** — it covers everything from a one-line bug-fix to a small multi-part feature, sized to a scope a senior engineer can hold in their head.

This hybrid is **opus-tier thinking work**, not a code transcript. It is the **blueprint** that `review_task` pressure-tests and that `implement` builds against — each task carries enough intent, interface, and test design that the implementer **cannot** misread you, but the literal test and implementation code are theirs to write. If you catch yourself pasting a function body or a full test, stop — that's the implementer's job.

## Ground first — consume the dossier

Read the investigation **`dossier.json`** the orchestrator produced: `{depth, recommendedApproach, findings[{subsystem,summary,files}], conventions, risks, openQuestions, citations}`. It already surfaced the structure, conventions, patterns, and the relevant modules — let it ground the conversation. Confirm and extend its findings against the real code; do NOT re-run a cold from-scratch exploration. Only read additional codebase areas the dossier did not cover or that you'll build directly against — read the actual types and interfaces you plan to build on.

## 1. Understand the goal (2–4 exchanges)

Lead with the dossier's `openQuestions` and `risks` — resolve those first rather than re-deriving questions cold. Propose the dossier's `recommendedApproach` as your default and pressure-test it with the user.

Ask focused questions — one at a time, always recommending an approach. This is a plain-text conversation: offer options inline as prose, then end your turn for the user to reply in chat. Do NOT use `AskUserQuestion` or any structured/popup question tool, and do NOT spawn or relay to another agent — *you* run this stage. Clarify scope, constraints, success criteria. YAGNI ruthlessly.

Task-tier means the scope is small enough that a senior engineer could hold the entire design in their head. **Calibrate the conversation to the change:** for a focused change or bug-fix where the user already knows what they want, keep it brief — confirm scope, risks, and the fix, then go; spend more design discussion only as the change grows. If the scope keeps expanding past hold-in-head, flag it — this might need to be Feature-tier.

## 2. Design the approach

Present the architecture in 200–300 word sections, validating each with the user. Cover: what components change, data flow, integration points, error handling, rejected alternatives. Briefer than Feature-mode brainstorming — just enough to make sound implementation decisions. Cite the real files and conventions you're building against (the dossier already surfaced many).

**Before you finalize, elicit prerequisites — the last questions you get to ask.** Everything after this document is autonomous (`implement` → `review_code` → `validate`, including the e2e/integration tasks in your blueprint), and a firewall makes asking the user impossible once the pipeline advances. So if any of that work needs something only the user can provide — a **credential or secret**, an **authenticated CLI** (`glab`/`gh`/cloud login), a **deploy/publish target**, an **account/project id** — ask the user **now**, while the conversation is open, and record it in the **Prerequisites / Required Access** item below (what it is, where the stage reads it from, the check that confirms it — **never the secret value itself**). An un-elicited prerequisite becomes a hard pipeline failure downstream. Most focused changes need none — only ask when the change actually reaches outside the repo.

## 3. Write the spec-plan hybrid

Write to the orchestrator-assigned path. The document has two major sections.

### Design Section

- **Purpose and success criteria** — concrete, testable criteria.
- **Architecture and approach** — rationale for the chosen approach, rejected alternatives.
- **Components and data flow** — what changes, how data moves, failure modes.
- **Integration** — how the feature becomes reachable from existing entry points.
- **Prerequisites / Required Access** — anything an autonomous stage needs that only the user provides (credential, authenticated CLI, deploy/publish target, account), as elicited above: what it is, which stage needs it, where the value lives (env var / secret-file path / pre-authed CLI — **never the value itself**), and the check that confirms it's present. Write "None" if the change stays inside the repo.

### Implementation Plan Section (the blueprint)

- **Scope** — what's being built, what's explicitly out of scope.
- **Current State** — diagnosis of existing conditions that motivate this work.
- **Tasks** — each task carries three things — **WHAT**, **HOW**, **WHAT-to-test** — describing the work precisely, never pasting the code:

  ```markdown
  ## Task N: [What this task proves/builds — the unit and its single responsibility]

  **Files:**
  - Modify: `path/to/file.ts` (lines 50–70)
  - Create: `path/to/new-file.ts`
  - Test: `path/to/test.ts`

  ### N.1 How — the implementation approach
  The unit's single responsibility · the interface/signatures and data shapes ·
  the exact files+paths to create/modify · the patterns to follow (cite real
  files/conventions) · what to reuse · the seams where it wires into existing code.
  Describe the logic precisely — do NOT paste a function body.

  ### N.2 Tests to write — the cases, the edges, what each asserts and why
  Name the specific test cases and the edge cases that actually matter here.
  For each: what it asserts and why — the behavior, the boundary, the failure
  mode. State the acceptance bar. Do NOT write the literal test code.
  Run via Strobe: `debug_test({ ... })` — name the expected failure-then-pass.

  ### N.3 Checkpoint
  One sentence: what works now that didn't before.

  **Edge cases covered:**
  - [Named boundary condition: why it matters → which test asserts it]
  ```

- **Execution order** — sequential/parallel blocks with dependency annotations; dependencies first, wiring last.
- **Files modified summary** — table mapping files to Create/Modify + change description.
- **Edge case coverage matrix** — requirement → test location → assertion.

## What the tests must be (so the implementer builds them right)

- **Observable behavior, not internals** — a test breaks only when the contract changes, never on a refactor. Assert outputs, side effects, state transitions — not `writer.nextIndex === 3`.
- **Falsifiable** — ban vacuous assertions (`toBeDefined`, "truthy"). Every test must be able to fail on a real bug.
- **Mock only at boundaries** — network, fs, time, randomness. Prefer the codebase's real test infra (temp dirs, in-memory stores) over mocks.
- **One behavior per test**, parameterized across inputs where the logic repeats.

## Edge cases — think adversarially per task

Boundaries (empty/zero/one/max/off-by-one) · invalid input · error paths (failure, corrupt state, permission, exhaustion) · concurrency (races, reentrancy, ordering) · state transitions (initial, already-there, invalid) · security (injection, path traversal, untrusted boundaries). Each task names which of these its tests must cover and why.

## End-to-end coverage — comprehensive but lite (the task flow has no separate e2e stage)

The task pipeline has **no dedicated e2e stage**, so the end-to-end coverage lives in *this* blueprint. It can't be as exhaustive as the Feature pipeline's e2e sub-flow (there's no separate environment-research or infra-build stage here) — but it **must be good enough to prove the change actually works through its real surface**, across whatever modalities the change touches. Add explicit **e2e / integration tasks** covering the applicable ones:

- **Backend / API / service** — exercise the real endpoint/handler/job end-to-end (request → response, or event → side-effect) against a real or realistic test datastore, **not a mocked unit**. Assert the observable result, the persisted state, and the error responses.
- **Frontend / UI** — drive the real **user journey** (the actual clicks/inputs that reach the feature) and assert the resulting DOM / state / navigation — not an isolated component render.
- **Visual** (whenever there's UI) — at least one screenshot/visual check of each new or changed view-state (empty, loading, populated, error, overflow), so a broken layout is caught — golden compare where the project has it, otherwise a described visual assertion.
- **Data flow across the seams** — wherever this change wires two parts together (a new route registered, two components now talking, new read/write of shared state), one test drives data in at one end and asserts it out the other.

State each as a blueprint — the journey/cases it drives, **what it asserts**, **where it lives**, and **how it's run** (real env + the project's harness) — never literal code. **Right-size to the change:** a backend-only bug-fix needs backend e2e, not visual; a new UI panel needs UI + visual. The **final task(s) must wire the feature into the app** (register routes, mount components, update config) — a plan that builds components but never connects them ships dead code.

## 4. User approval gate

Present the document for review. Iterate on feedback. When the user approves, the stage is complete — record it in `state.json` (`done[]`, `phase`, `artifacts`) and advance. **This is the only `state.json` write for the whole stage: don't update it mid-conversation, and keep the design + decisions in the document, not in state.** You run this stage yourself; there is no signal to emit.

## Quality Bar

Every task specifies its test cases and edge cases (what each asserts and why) and its implementation approach (responsibility, interfaces, files, patterns, reuse) precisely enough that `review_task` and `implement` cannot misread intent — **without** the literal test or implementation code. Edge cases mapped to test locations; file modifications explicit with line-number precision. The implementation-plan section is a blueprint the downstream stages refine and build, not a transcript anyone copies code from.
