---
name: validating
description: Prove it works before the owner looks — run the protocol, drive the real surface end to end, gate with gestalt where surfaces changed, publish a proof board with evidence per claim, loop fix and re-verify until every card is judged, and say plainly what remains unverified.
phase: validate
---

# Validating

Automated tests pass while the product is still obviously broken to a human eye, and an
automated judge has signed criteria green that were not. Validation is therefore layered:
the protocol, the real surface, the gestalt gate, the proof board, and the owner last. There
is no user in this phase until the board is ready; nothing here asks.

## Depth by rung

- **R0**: the test that fails without the fix, seen red then green, plus whatever check the
  change implies (a build, a rendered screen, a routed message). Paste the counts.
- **R1**: the brief's checks, run and pasted into `PROGRESS.md`.
- **R2 and R3**: everything below, sized to the surface. At R3 a coverage pass over a large
  surface is a sweep: haiku or sonnet agents each check a slice against one schema, you
  synthesise and judge.
- **R4**: per phase at phase close, and a final pass against `S1..Sn` with evidence per
  criterion before the completion promise.

## 1. The protocol

Read the spec's validation protocol and its prerequisites. Run each prerequisite check first;
a missing prerequisite is recorded as a failed step with the env var or CLI it should come
from, the rest of the protocol still runs, and the report is `NEEDS_ATTENTION`. Never
authenticate, mint or substitute a credential. Run each command, capture output and exit
code, judge against the stated success. Fix what fails with minimal targeted changes, up to a
handful of fix-and-rerun cycles; undo a fix that makes things worse; stop early on a circular
regression and report it.

## 2. The real surface

E2E means the real application runs in the real environment: real host, real server, real
window, real bytes on the wire, the real deployment boundary. A component rendered in a
simulator with simulated messages is a unit test wearing a costume, and the polytimbral
gauntlet's critical bug (two note queues, one per binary, silent output when hosted) was
invisible to every test that kept producer and consumer in one process.

- Launch programmatically, wait for readiness by signal or poll (never sleep), drive through
  the real interface, observe real outputs, tear down clean, isolate per test.
- Assert on user-visible behaviour a real user would hit in their first minutes, with at
  least one assertion per scenario that would catch a real regression. "If this passes but
  the feature is broken, what did I miss."
- A dependency is mocked only when running it is genuinely impractical (paid with no free
  tier, proprietary hardware), at the outermost boundary, with recorded real responses.
- Visual checks are dual-path where the project has goldens: pixel diff first, then an LLM
  check with negative probes. Goldens are blessed only from a frame that already passed a
  gestalt judgment, with the judging run recorded; an unjudged golden freezes a defect into
  the baseline.
- All bugs found here are yours to fix, pre-existing or not, with a red-then-green test.

## 3. The gestalt gate

Where the work built or changed a user-visible surface, run a gestalt walk on it with the
gestalt plugin (`/gestalt walk`, or the walk skill's procedure driven by hand): capture the
rendered artifact, read numbers from the structured sidecar never from pixels, judge
closed-world against the charter written at Spec time, sweep every affordance to intent,
hop one entity across every surface that shows it, verify every candidate finding by a second
source or a fresh skeptic with planted probes, restore any state you wrote and prove it.

Gate rules:

- **BLOCK** on any confirmed high finding; any confirmed finding on a surface this work built
  or changed; a built surface with no charter or no capture; a harness integrity failure on a
  surface this work owns; a policy breach or a missing restore verification.
- **ADVANCE** otherwise, recording confirmed findings on untouched surfaces as pre-existing,
  design gaps as owner gates, and charter corrections as cited `benign.md` lines.
- A high the work cannot legitimately fix is deferred only by landing a deterministic oracle
  that pins it (red-verified, registered in the suite CI runs). Deferral costs an oracle;
  dismissal costs a cited benign line. Never silently.
- Three outcomes per check, not two: PASS, FINDING, NOT VERIFIED. Uncovered surface never
  counts as green.

A walk is driven, never built: throwaway scripts in the run directory, no harness.

## 4. The proof board

For a user-visible surface at R2 and above, and always at R4:

1. **Catalog** the checks: one item per thing to prove, from the success criteria, the
   charters, the plan's e2e scenarios and the gestalt findings. Fields per the `boards` skill.
2. **Prove** each item yourself or with fan-out agents per area (opus for judgement, sonnet
   for mechanical captures): a verdict, a summary of what you did and saw, evidence files
   (screenshot, audio, log), defects found with their status. Items only a human can judge
   (taste, feel, hardware in hand) are marked `human`.
3. **Build and publish** the board (`scripts/proof-board.py`, then the Artifact tool with
   the `db` capability). Your verdicts are frozen in the page; the owner's go into the
   database.
4. **Fix-review rounds**: the owner judges cards; you read the verdicts back, fix every
   `issue` with a red-then-green test and a mutation check, redeploy, re-prove the affected
   cards, republish a new version, backup the verdicts. Repeat until every card carries an
   owner verdict. What is left is listed as open in the handoff, never quietly dropped.

The owner's "does this look right" is a taste call and a gate; your 7 out of 10 is not a
pass.

## 5. The report

`validation.md`: a verdict table (check, method: measured | analytic | not measured, result,
evidence path), the gestalt verdict with its run doc, the board URL and its tally, then a
plain list of what remains unverified. Result: `PASS`, `PARTIAL` or `NEEDS_ATTENTION`.

## Returning

`VALIDATION <result> — protocol <n>/<n>, e2e <n>/<n>, gestalt <ADVANCE|BLOCK|N/A>, board
<url> <tally>, unverified: <list>, report at <path>`.
