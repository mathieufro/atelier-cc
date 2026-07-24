---
name: speccing-epic-multipart
description: "The epic speccing head: a two-level topic x axis research fan-out, then a multipart normative spec set (spec.md + satellites + decisions log + constraints) precise enough for autonomous execution."
stage: research, write_spec
---

# Speccing an epic, multipart

An epic is too big for one dossier and too big for one spec file. This skill covers the two
stages that produce the normative document set the rest of the pipeline executes against:
**`research`** (the investigation fan-out) and **`write_spec`** (authoring the set). The
design conversation between them is `brainstorming-epic`.

The bar is different from a feature spec. A feature spec is read by a human who will fill
gaps with judgment. **This spec is read by agents who will fill gaps with invention.** Every
ambiguity becomes a divergence you discover three phases later.

---

# Stage: `research`

## Two levels, not one

A flat 2–4 agent grounding fan-out is right for a feature and useless here. Structure it as
**topic × axis**:

1. **Split the epic into independent topics** — the natural subsystems. Four to eight.
2. **Run a fixed axis template per topic**, one agent per cell:
   - **grounding** — what already exists in *our* tree, `file:line`
   - **algorithms / state of the art** — how this is actually done
   - **performance at target scale** — does the approach survive our real numbers
   - **prior art / products** — what shipped products do, and what they got wrong
   - **community / demand** — what users of this class of thing actually complain about
   - **one topic-specific hard-problem axis** — the thing that makes *this* topic hard
3. **Roll each topic up** into `research/<topic>-dossier.md`.
4. **Index the set** in `dossier.json` — the standard shape, with `findings` pointing at the
   per-topic dossiers rather than inlining them.

Adapt the axis list per topic; drop an axis that is genuinely empty rather than padding it.
The point is that every topic is examined from the same angles, so a gap is visible as a gap.

## Rules

- **Cite or drop.** A claim about our tree carries `file:line`. A claim about the world
  carries a source. An uncited claim in a dossier becomes an uncited assumption in the spec.
- **Record what you could NOT determine.** An open question in the dossier is worth more than
  a confident guess, because the guess will be built on.
- **Prior art is for failure modes, not features.** What did shipped products get *wrong* is
  the higher-value question.

---

# Stage: `write_spec`

## The document set

| File | Role |
|---|---|
| **`spec.md`** | The normative core: WHAT and WHY, numbered success criteria, definitions, budgets, edge cases, fallbacks, Validation Protocol, Prerequisites |
| **`spec-<facet>.md`** | Satellites, only when a facet is large enough to drown the core — parameters, UI, protocol. Split by *facet*, never by chapter |
| **`brainstorm-decisions.md`** | Append-only log `D1..Dn`: decision, rationale, alternatives rejected. **Never edited** |
| **`design-constraints.md`** | Human-issued binding constraints, **verbatim**. Not paraphrased, not "interpreted" |

Split only when a facet genuinely drowns the core. Two well-organized files beat five
cross-referencing ones. Every satellite is referenced from `spec.md` and owns its facet
completely — a fact lives in exactly one file.

## What makes a spec executable rather than merely correct

- **Numbered success criteria `S1..Sn`.** Each independently checkable. These are what the
  roadmap maps phases onto and what the terminal completeness critic checks. A criterion no
  agent can evaluate is a wish.
- **Definitions section.** Every term with a project-specific meaning, defined once. Agents
  will not converge on your meaning of "session" or "slot" by intuition.
- **Budgets as numbers.** Latency, memory, throughput, size — with the measurement method
  named. "Fast" is not a budget; "≥1× real time measured by X on profile Y" is.
- **Edge cases enumerated**, with the intended behaviour for each. An unlisted edge case gets
  invented.
- **Fallbacks pre-designed.** For every risky mechanism, state now what happens if it does
  not work. Deciding that mid-execution, autonomously, is where an epic goes sideways.
- **Validation Protocol** — the literal commands proving the epic is done, with success
  criteria. The terminal `validate` stage executes this verbatim.
- **Prerequisites / Required Access** — every credential, authenticated CLI, deploy target or
  account a downstream stage will need, named with where the value lives and how a stage
  checks it. **Never the secret itself.** This is elicited in the design conversation, and it
  is the one class of thing no default can substitute for.

## Precision habits that pay

- Write **assertions, not aspirations**: "the scan runs at 1 kHz" not "the scan should be
  fast".
- Where you say a thing must not happen, say **how it would be detected**.
- Mark anything deliberately unresolved as **OPEN**, with who resolves it and when. An
  invisible open question is resolved by whichever agent trips over it first.
- Cross-reference by **stable id** (`S4`, `D12`), never by section number.

## Amendments — how the spec changes after review

The spec is versioned by amendment, not by silent edit. Findings from `review_spec`, and
deviations discovered during execution, land in a permanent **`## Amendments`** section on
`spec.md`: one `finding → resolution` line each, waivers included with their reason.

`brainstorm-decisions.md` is **never** rewritten. If a decision is superseded, the
supersession is an amendment entry. The log is a record of what was decided and why, and its
value is that it stays true.

## Returning

- `SPEC WRITTEN — spec.md (<n> criteria S1..S<n>), satellites: <list>, decisions D1..D<n>, <n> OPEN, prerequisites: <list>`
