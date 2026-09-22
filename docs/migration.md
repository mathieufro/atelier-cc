# Migrating to the single flow

For the three repos that run atelier-cc: erae-monorepo (and its polywip and dev checkouts),
fine-line, dream-machine. Nothing in a repo's `.atelier/` needs rewriting.

## 1. Update the plugin

The plugin is installed from the `atelier` marketplace (`mathieufro/atelier-cc`). Once this
branch is on `main`:

```bash
claude plugin marketplace update atelier && claude plugin update atelier@atelier
```

Or, from an interactive session, `/plugin marketplace update atelier` then
`/plugin update atelier@atelier`. Check with `/atelier status` in any repo: it prints
`rung` for new runs and `type` for old ones.

## 2. In-flight pipelines

- A running pipeline created by the old flow keeps working. Its `state.json` carries `type`
  and a typed `plan[]`; the hooks honour the persisted `plan[]` exactly as before, so the
  Stop, heartbeat and SessionStart hooks keep gating on its last stage (`validate`).
  `/atelier resume <id>` maps each remaining old stage onto the phase it belongs to
  (`write_plan` and `write_blueprints` are Spec, every `review_*` is Review, `implement`
  and `ws_*` are Execute, `e2e` and `gestalt` are Validate).
- fine-line `2026-09-03-pro-dsp-epic-0c7d` and erae `2026-09-09-liaison-next-level-buzz-1408`
  are the two long runs still open. They already work the way the new Execute phase
  describes (loop brief, ledger, batch skeptic, per-phase plan written at phase start, owner
  checkpoints). Resume them as they are; do not re-create them.
- Runs with no `state.json` (some polywip task runs) are not pipelines to the hooks and are
  unaffected.

## 3. CLAUDE.md sections now carried by the plugin

`docs/precepts.md` carries, verbatim or near-verbatim, the Delegation, Verification budget,
Long-running work, Standing order, Working style and Reply length rules. They are read once at
Frame by every run. Each repo may keep its own copy (they are binding for non-atelier
sessions too), but it no longer needs to restate them for pipeline runs. What stays
repo-specific and should remain in the repo's CLAUDE.md:

- erae-monorepo: the heavy-job gate and the box rules, the gestalt rules file
  (`.claude/rules/gestalt.md`), release and ops rules, the bug-records rule. Note that the
  Verification budget and Reply length sections exist only in the polywip copy today; the
  plugin now applies them everywhere.
- fine-line: the job-slot semaphore, the gate scoping decisions (D176, D177, D181), the
  attribution rule, the Rust review question.
- dream-machine: `cdc/engineering-defaults.md` stays the source of engineering defaults; the
  owner decision board it used (`cdc/decision-review.json`) is now the `boards` skill's
  decision card kind. Convert the existing JSON to a `board/catalog.json` with
  `kind: "decision"` cards if the board is still live; otherwise leave it.

## 4. Skills and commands that go away

- Plugin skills removed: `brainstorming-epic`, `brainstorming-feature`,
  `brainstorming-roadmap`, `task-brainstorming`, `speccing-epic-multipart`, `writing-plans`,
  `writing-blueprints`, `reviewing` (rewritten), `fixing`, `fixing-specs`,
  `implementing-plans`, `executing-workstreams`, `simplifying-implementation`, `validating`
  (rewritten), `e2e-gating`, `writing-e2e-plans`, `e2e-validation`, `gestalt-qa`. Any repo
  prompt that names one by `atelier:<name>` should name the phase skill instead:
  `atelier:brainstorming`, `atelier:speccing`, `atelier:reviewing`, `atelier:executing`,
  `atelier:validating`, `atelier:boards`.
- The gestalt plugin is unchanged and still installed separately; Validate calls
  `/gestalt walk` and keeps the gate rules.
- The `ralph-loop` plugin is no longer needed for atelier runs: the Stop hook is the loop and
  the completion promise is the stop condition. Keep it only for non-atelier loops.
- `~/.claude/commands/*` still holds sixteen broken symlinks to pre-plugin skills
  (`brainstorming`, `bugfixing`, `compiling`, `reviewing-*`, `writing-*`). Delete them.
- The user-level `benchmarking` and `responding` skills assume the old pipeline types; they
  need a small update (`type` becomes `rung`) before their next use.

## 5. New conventions each repo picks up

- `.atelier/pipelines/<id>/` now holds `brief.md`, `PROGRESS.md`, `gates/`, `board/` and
  `validation.md` alongside the spec and plan. The August-style wave specs under
  `.atelier/specs/` are exactly an R2 run's spec plus plan; keep writing them, or let
  `/atelier` write them.
- Charters for new user-visible surfaces are written at Spec time into the repo's
  `gestalt/charters/` (erae, liaison); a repo without a gestalt workspace bootstraps one with
  `/gestalt bootstrap` before its first R2 run with UI.
- Proof boards are built with `scripts/proof-board.py` from the plugin, published with the
  `db` capability, and their verdicts backed up per round under `board/`. The scratchpad
  generator used for the polytimbral board is superseded.
- Gate files replace `OWNER-CHECKPOINTS.md` and `gates/*-signoff.md`: same content, one
  shape, only the owner writes VERDICT and SIGNED.

## 6. What to try it on first

- erae-monorepo-polywip: the next sequencer or Lab task at R1 or R2, in-tree. It exercises
  Frame, a two-exchange Brainstorm, a wave-spec plan, a batch skeptic and a small board.
- fine-line: the next phase of the DSP epic through `/atelier resume`, to check that the
  per-phase plan and phase close read naturally from the rewritten skills.
- dream-machine: its next spec-stage decision through the decision board, reading the
  clicks back into `decisions.md`.
