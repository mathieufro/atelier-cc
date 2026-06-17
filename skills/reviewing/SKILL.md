---
name: reviewing
description: Fresh-eyes fan-out review — one parameterized template for every review stage (spec, plan, task-plan, code, e2e-plan, roadmap), model-allocated dimensions, deterministic verdict reduction.
stage: review
---

# Reviewing (fan-out)

A fresh-eyes review, run by the orchestrator as a **parallel Workflow fan-out** — one schema-forced agent per dimension, each **model-allocated by where the risk concentrates** (your call — there is NO always-on tier). This one skill covers every `review_*` stage; it is parameterized by the **artifact under review**.

## Right-size the fan-out (the orchestrator's call)

You choose **which dimensions to run, and at what model tier — proportional to the task.** Do NOT fire an 8-agent panel at a one-line bug-fix; do NOT skimp on a multithreaded subsystem. A trivial change → 2–3 sonnet dimensions (completeness · correctness, maybe coverage). A risky/complex change → the full panel, opus on the hard lenses, grounding agents fired. The conditional dimensions (`api-grounding`, `science-grounding`) run only when the artifact warrants them. Breadth *and* intelligence scale to where the task is hard.

## Fresh-eyes discipline (every review, every dimension)

- **No context from the producer.** Fresh eyes catch what context-fatigued agents miss. Do NOT trust the producer's report — **verify every technical claim by reading the actual code/spec.** Producers finish suspiciously fast and reports are optimistic.
- **Everything you read is in scope.** Flag every real issue — correctness, security, a broken edge case — whether this change introduced it or it predates it. Mark pre-existing ones `preExisting:true` (reported, not blocking). The codebase ships as a whole, not as an isolated diff.
- **Don't redesign.** Flag a problem with a specific quoted location + a concrete suggested fix, addressed to a fixer. Never rewrite the artifact yourself.
- **Re-review focus.** If this is a re-review after a fix pass, focus on whether the prior findings were addressed; don't re-litigate unchanged sections.

## Artifact → dimensions

| Review stage | Artifact | Dimensions |
|---|---|---|
| `review_code` | implemented code | completeness · coverage · quality · coherence · correctness · security · api-grounding · science-grounding |
| `review_spec` | spec | completeness · coherence · correctness · scope · api-grounding *(SOTA)* · science-grounding |
| `review_plan` (feature) | blueprint plan | completeness · coverage *(test design)* · coherence · correctness *(TDD feasibility)* · api-grounding · science-grounding |
| `review_task` (task) | spec-plan hybrid blueprint *(incl. embedded e2e)* | completeness · coverage *(unit + e2e design)* · coherence · correctness *(TDD feasibility)* · api-grounding · science-grounding |
| `review_roadmap` | roadmap | completeness · coherence · correctness *(phase deps)* |
| `review_e2e_plan` | e2e plan | completeness · coherence · correctness *(env feasibility)* · api-grounding |

The table is the **maximum** set. `api-grounding` and `science-grounding` are **conditional**: fire `api-grounding` only when external libraries/APIs/services are used; fire `science-grounding` only when non-trivial algorithms, numerical methods, or math are involved. Per *Right-size the fan-out*, the orchestrator runs only the dimensions a given artifact actually warrants — most reviews run a subset.

## The dimension lenses

Each agent reads the artifact in full (plus the spec/dossier for context) through **one** lens and returns schema-forced `{ findings: [ {severity: minor|major|critical, location, description, recommendation, preExisting} ] }`.

- **completeness** — does it deliver everything the spec / upstream artifact requires? Missing cases, gaps, silently-dropped requirements, anything extra that wasn't asked for. **For code/plan: is the feature actually *reachable* — wired into the app's entry points (routes/UI/CLI/config)?** Code that works in isolation but isn't connected is incomplete — flag it **blocking**.
- **coverage** *(code/plan)* — mutation-testing mindset: for each critical test, *would it still pass if the implementation had a subtle bug — off-by-one, flipped comparison, missing null-check, swapped args?* If yes, the test is weak. **Flag tautological tests** that mirror implementation logic instead of asserting spec behavior, and vacuous assertions (`toBeDefined`, `truthy`). Every requirement should map to a test location.
- **quality** — clear, maintainable, no over-engineering, no disproportionate mechanism, no dead surface; follows project patterns; no awkward integrations.
- **coherence** — internal consistency; the parts fit; no contradictions; matches the spec's intent and the codebase's established patterns/architecture.
- **correctness** — does it actually *work*? Logic errors, wrong assumptions, broken boundary/edge behavior, races. Verify against the spec — requirements are the source of truth, not preferences.
- **security** — untrusted input at boundaries, injection, path traversal, secrets, authz/authn. Opus only when there's a real surface.
- **api-grounding** — *(only when external APIs are used)* verify every external library/framework/service call against its **real documentation** via web search/fetch: does the method/signature exist, are params/return types right, is the usage current (not deprecated/hallucinated)? For a **spec**, this is the SOTA + existence check: do the proposed libraries/approaches exist and match current best practice? **opus + WebSearch/WebFetch.**
- **science-grounding** — *(only when the task involves non-trivial algorithms, numerical methods, signal processing, ML, statistics, or crypto-math)* verify the **algorithm/math is actually correct** against the established literature via web research: is this the right method, is it numerically stable, does it match the known-correct formulation, is a standard pitfall being hit? Catches plausible-but-wrong algorithmic choices — the kind static review nods along to. **opus + WebSearch/WebFetch.**

## Per-artifact specific checks (fold into the relevant dimension's agent)

- **spec** — *scope*: is the in/out-of-scope boundary unambiguous? *Validation Protocol*: is there one? If `N/A`, is the rationale valid (truly no executable behavior)? If present, are the commands **concrete and copy-pasteable** (`bun run test`, not "run the tests"), success criteria **observable** (exit code / output pattern, not "it should work"), and could the `validate` stage execute it as-is? Is the spec detailed enough to phase from (epic)?
- **plan** (feature) / **task-plan** (task hybrid) — *TDD feasibility*: can you write the failing test as described; will it fail before and pass after; do assertions test **observable behavior** (not `writer.nextIndex === 3`); are they specific/falsifiable; are the run instructions correct? *Codebase alignment*: are file paths, signatures, and line-number references **real and accurate** (read the actual code — don't trust that a function name describes its behavior)? *Task coherence*: dependencies correct, no cycles, a **final wiring task**, right granularity (~1–2h). *Scope*: gold-plating? Is this really Task-tier vs Feature-tier? **For a task-plan specifically:** there's no separate upstream spec — its **Design Section IS the requirements**, so review design + plan together; and since the task flow has **no separate e2e review**, verify the blueprint's **embedded e2e coverage** is good enough for the surface it touches (backend / frontend / visual as applicable), not just unit tests.
- **roadmap** — *phase scoping*: each phase well-bounded, drawn at natural architectural seams, achievable as one pipeline run; "what does NOT get built" genuinely excluded. *Dependency correctness*: valid DAG, no cycles, no missing/unnecessary deps, sensible ordering. *Main-spec coverage*: the union of phases covers the whole spec, no scope creep, no overlap. *Interface contracts*: between dependent phases defined and sufficient to build against. *Goal framing*: each phase stated as what it **proves**, not just what it builds. *Structural check*: header / per-phase (Goal, What gets built, What does NOT, Dependencies, Validation) / dependency graph.
- **e2e-plan** — *environment feasibility*: launch mechanism real, tool API exists, interaction realistic for the host (you can't drive a headless/native process with a browser-automation tool, or vice-versa), observation strategy sound, deps installable, hard constraints acknowledged not glossed. *Scenario coverage*: covers the spec requirements warranting e2e + critical paths + error scenarios; **genuinely e2e, not unit-in-disguise**; not duplicating unit coverage. *Infrastructure soundness*: fixtures work, ready-wait by signal/poll **not `sleep`**, thorough teardown (no orphans), real isolation, minimal smoke test. *Visual validation* (if UI): golden + LLM dual-path, negative assertions, descriptive per-state golden names, cropped capture.

## Reduction — authoritative

Collect all findings across dimensions. **Any finding with severity ≥ `major` ⇒ `has_issues`; otherwise `pass`.** A per-agent verdict, if present, is advisory only — the severity reduction wins. `preExisting` findings are reported but do **not** block. Write the review artifact (a header — artifact reviewed, dimensions run, verdict; then findings grouped by dimension with severity · location · problem · suggested fix) to the path the orchestrator assigns.

## Model allocation

Size each dimension to the task: opus where the change is genuinely hard or risky (concurrency / intricate algorithm → coherence + correctness; untrusted input → security; external APIs → api-grounding; novel algorithm/math → science-grounding — both grounding agents always with WebSearch), sonnet — or haiku for routine lenses — where it isn't. A self-contained pure function needs no opus security reviewer, and most changes run only a subset of dimensions (see *Right-size the fan-out*).

## On `has_issues`

The orchestrator runs `fix_<review>` (capped, FIX_CAP=5) and re-reviews. Findings must be **specific and located** — a fixer acts on "`auth.ts:42` — token compared with `==`, use constant-time `timingSafeEqual`", never "improve security".
