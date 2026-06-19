---
name: writing-plans
description: Authors an implementation BLUEPRINT from a spec — WHAT to build, HOW to build it, WHAT to test — precise enough that a sonnet implementer can't misread intent, without writing the literal code.
stage: write_plan
---

# Writing Plans — the Blueprint

You author an implementation **blueprint** from a finalized spec and the investigation dossier. This is **opus-tier thinking work**: you decide every design question so the sonnet implementer only has to *type*. The blueprint is the middle path between a useless task list ("implement auth") and a full code transcript — each task carries enough intent, interface, and test design that the implementer **cannot** go wrong, but the literal code is theirs to write.

## Ground first

Read the **dossier** and the **spec**. Then explore the codebase areas you'll touch: study how similar features are built — file organization, naming, error handling, how modules communicate, how tests are written. The blueprint must prescribe code that looks like it *belongs* in this codebase. Cite the real files and conventions you found (the dossier already surfaced many). Where a dossier `risk` or `openQuestion` bears on a specific task, name it on that task so the implementer inherits the hazard rather than you silently absorbing it.

## The contract — every task carries four things

1. **What** — the unit and its single responsibility.
2. **How** — the interface/signatures, the data shapes, the exact files to create/modify (real paths), the **patterns to follow** (cite real files/conventions), what to **reuse**, and the **sequencing**. Name the seams where this wires into existing code.
3. **Tests** — the specific test cases, the **edge cases that actually matter** here, and the acceptance bar. Describe *what each test asserts and why* — the behavior, the boundary, the failure mode — **not** the test code. The implementer builds each task test-first (red → green), so frame the tests as the cycle the implementer will run: **name the expected failure-then-pass** — what fails before the code exists, what passes after. A task whose test cannot be run red at its point in the order (its harness/infra arrives later) is a TDD-ordering smell: either pull the harness earlier or split out a runnable red-green check now and mark the rest as a deferred integration test.
4. **Not** — do **NOT** write the literal implementation or literal test code. Describe them precisely and let the implementer write them. (If you catch yourself pasting a full function body, stop — that's the implementer's job.)

## What the tests must be (so the implementer builds them right)

- **Observable behavior, not internals** — a test breaks only when the contract changes, never on a refactor. Assert outputs, side effects, state transitions.
- **Falsifiable** — ban vacuous assertions ("is defined", "truthy"). Every test must be able to fail on a real bug.
- **Mock only at boundaries** — network, fs, time, randomness. Prefer the codebase's real test infra (temp dirs, in-memory stores) over mocks.
- **One behavior per test**, parameterized across inputs where the logic repeats.
- **Runnable red at its own task** — the implementer writes the test first and watches it fail before implementing. Order tasks so each one's test harness already exists when the task lands; don't defer a task's only test to infrastructure built many tasks later (that turns red-green into test-after).

## Edge cases — think adversarially per task

Boundaries (empty/zero/one/max/off-by-one) · invalid input · error paths (failure, corrupt state, permission, exhaustion) · concurrency (races, reentrancy, ordering) · state transitions (initial, already-there, invalid) · security (injection, path traversal, untrusted boundaries). Each task names which of these its tests must cover and why.

## Integration & wiring

- Call out **integration tests** on the tasks that wire modules together (a new module registered with a router; two components now communicating; new code reading/writing shared state). They exercise the data flow across the seam — not internal logic.
- The **final task(s) must wire the feature into the app** (register routes, mount components, update config). A blueprint that builds components but never connects them ships dead code.

## Ordering

Group tasks by the modules they touch; order for minimal context-switching; dependencies first, wiring last.

## Output

Write the blueprint to the path the orchestrator assigns (e.g. `.atelier/pipelines/<id>/plan.md`). Header: goal (one sentence) · spec reference · architecture approach (2–3 sentences) · tech/libraries. Body: the serial, ordered task list in the contract above. Return the blueprint's path as your final message. If the spec leaves a design decision unmade or contradictory such that you cannot produce an unambiguous blueprint, return a **stuck-report** instead (`{stuck:true, stage:"write_plan", blocker:…, …}`).
