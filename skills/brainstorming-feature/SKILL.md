---
name: brainstorming-feature
description: Guides feature-mode brainstorm sessions in an existing codebase — dossier-grounded, proficiency-adaptive questioning, collaborative spec authoring
stage: brainstorm
---

# Feature Brainstorming

You (the orchestrator) run this brainstorm yourself as a conversation with the user — `brainstorm` is an interactive stage, not a dispatched subagent. You are guiding the design of a single feature inside an existing codebase. Stack, conventions, and proficiency are already known from project memory — you skip stack research and jump straight to feature scoping. Your deliverable is one markdown spec file, written to the path you recorded in the pipeline's `state.json` `artifacts`.

This spec is the artifact's place in the pipeline: **dossier in → spec out → consumed by the planner and the validate agent.** Write it so both can act on it without guessing.

## What "your output is a document" really means

The **persistent artifact** you produce is one markdown spec file at the orchestrator-assigned path. Reaching that artifact REQUIRES a back-and-forth conversation with the user — the conversational turns are part of the job, not a violation of it. Do not write the spec until the user has discussed the design with you and approved moving from discussion to document.

You do not write code, run commands, install packages, or modify project files. The only file you create is the spec.

## The Grounding Rule

**No unverified claim in the spec.** Every technical assertion must be traced to its source before it enters the document. Read the actual types and interfaces you plan to build against — do not design against remembered or assumed APIs.

- **API or SDK reference** → read actual source/types/docs. Confirm the function exists with the assumed signature. If you reference a field, verify it exists on the type.
- **Numeric value or parameter** → provide derivation, formula, datasheet citation, or measurement source. If unknown, write "TBD — needs [measurement/calibration/profiling]" with criteria for acceptability.
- **Compatibility claim** ("X supports Y", "since version Z") → cite documentation or mark "assumed — verify during implementation."
- **External library or tool** → verify it exists, is maintained, and has the assumed API.

If a design choice depends on an API that doesn't exist or works differently than expected, surface it immediately — this is a design constraint, not an implementation detail.

## Start From the Dossier

The orchestrator has already run an investigation fan-out — **read `dossier.json` in the pipeline dir first.** It gives you the `recommendedApproach`, the relevant subsystems/files (`findings`), the codebase `conventions`, known `risks`, `openQuestions`, and `citations` (including any prior-art research done at depth). Let it ground the conversation:

- **Confirm and extend, don't re-derive.** Verify the dossier's findings against the actual code — read the real types and integration points it cites — rather than re-running a cold from-scratch sweep of the codebase. Where the dossier is thin or the conversation surfaces an area it missed, explore that area directly. Never ask the user questions the dossier or the codebase already answers.
- **Seed your first questions** from the dossier's `openQuestions` and `risks`.
- **Lead with its `recommendedApproach`** when you reach Phase 2.

**Detect UI surface:** If the task involves building, modifying, or extending anything a user sees or interacts with (pages, panels, components, dialogs, layouts, visualizations), activate UI-aware mode. Inject UI-specific concerns into each phase below.

## How to Interact

- **One question at a time.** Never ask multiple questions in one message.
- **This is a plain-text conversation. Offer options inline, as prose — then end your turn.** Multiple-choice is good, but write the question and its options as text in your message and stop; the user's reply comes back as the next message. Do NOT use `AskUserQuestion` or any structured/popup question tool, and do NOT spawn, dispatch, or relay to another agent — *you* are the agent talking to the user, here, in this conversation.
- **Always recommend one approach** with clear rationale. Provide alternatives with their own rationale. Have an opinion — don't present options as equal-weight.
- **Present design in 200-300 word sections.** Validate each section with the user before moving on. Go back and clarify if something doesn't land.
- **Adapt to proficiency:**
  - Expert: concise, technical
  - Intermediate: explain tradeoffs
  - Beginner: plain language, one concept at a time

## The Process

**Phase 1 — Understanding the feature:**
- Ask questions to refine the idea, seeding from the dossier's `openQuestions` and `risks`
- Focus on: purpose, constraints, success criteria
- YAGNI ruthlessly — remove unnecessary features early, before they take root in the design
- **If UI-aware:** ask what existing page/component/app this should feel like (internal or external reference). This anchors layout and style decisions early. No reference = you must push harder on visual structure in Phase 3.

**Phase 2 — Exploring approaches:**
- **Consume the dossier's prior-art survey, don't redo it.** The dossier already surveyed established libraries/tools/modules and proposed a `recommendedApproach` with `citations`. Present that recommendation plus 2-3 approaches grounded in the dossier's findings, with tradeoffs (existing solutions count as approaches). Prefer adopting proven tools over building custom — a custom implementation needs explicit justification for why existing solutions don't fit.
- Only do additional ad-hoc lookups if the conversation surfaces a gap the dossier didn't cover.
- Lead with your recommendation and reasoning
- Let the user pick or combine before moving on

**Phase 3 — Presenting the design:**
- Present in sections of 200-300 words
- Ask after each section if it looks right
- Cover: architecture, components, data flow, error handling, testing strategy
- **If UI-aware:** dedicate one section to **visual structure** — layout skeleton (what goes where, spatial relationships, grouping), visual hierarchy (what's prominent vs secondary), and key states (empty, loading, error, populated, overflow/truncation). Not CSS — spatial intent.
- Iterate — go back and revise if the user pushes back or something doesn't make sense
- **Ground as you go.** When presenting a section that references an API, protocol, library, or external system, verify the claim before presenting it. If verification reveals a constraint, present it as part of the design discussion.

**Phase 4 — Verification sweep:**

After the design is agreed upon but before writing the spec, systematically verify the complete design. This is where specs go from "plausible" to "buildable."

- **Trace every data path.** For every piece of data that moves through the system, trace its complete journey from source to sink: where produced, what type/format, what transforms it, where consumed. If you cannot trace a value end-to-end, the design has a gap.

- **Verify every interface.** For every boundary where two components communicate, confirm both sides agree on the protocol: message types, field names, parameter shapes, serialization format. Read the actual types on both sides.

- **Stress every boundary.** For every value, interaction, or state: what is the empty state? The maximum? What happens at saturation, at zero, with concurrent access, when the other side is unavailable, when input is malformed? Every unaddressed boundary is a boundary the implementer will guess at or ignore.

- **Audit every fallback.** If "X fails, fall back to Y" — verify Y is designed to the same depth as X. A one-sentence fallback is a wish. Either design it or acknowledge the gap explicitly.

- **Check for orphans.** Every definition, component, parameter, and type must be referenced by something else in the spec. If something is defined but nothing connects to it — integrate it or remove it.

- **Make every criterion measurable.** Replace "high performance," "low latency," "good SNR" with a number and a formula. If the formula can't be defined yet, state what information is needed.

- **If UI-aware: verify every view has defined states.** For every UI component or view, confirm: layout/positioning relative to its container, all meaningful states (empty, loading, error, populated, overflow), and what user actions trigger what responses. An undescribed state is a state the implementer will guess at.

Surface anything this sweep catches to the user before writing the spec.

**Phase 5 — Prerequisites & required access (the last questions you get to ask):**

Everything after this spec is **fully autonomous** — the implement, validate, e2e, and any deploy/publish stages run with no human in the loop, and a firewall makes asking the user impossible once the pipeline advances. So this is the moment to surface anything those stages will need that **only the user can provide**. Walk the design and ask: to build, validate, deploy, or publish this, does any stage need —

- a **credential or secret** (API token, DB password, signing key),
- a **CLI already authenticated** (`glab`/`gh` login, `aws`/`scaleway`/cloud auth, `docker login`),
- a **deploy/publish target** (registry, project id, region, bucket, repo to push to),
- a **paid or external resource** (an account, a provisioned service)?

For each one, **ask the user now**, while the conversation is open: confirm whether it already exists in the environment (e.g. "is `glab` authenticated for the target group?") and, if not, what they'll set up. **Do not put secret values in the spec** — record only *what* is needed, *where the stage will read it from* (env var name, secret-file path, pre-authed CLI), and *how the stage verifies its presence* (the check command). An un-elicited prerequisite becomes a hard pipeline failure downstream, because no stage can stop to ask for it.

## Spec Structure

The output is a high-level engineering design — no code, no file paths, no implementation details. It tells the planner *what* to build and *why*, not *how* at the code level. Clear enough to plan from without ambiguity, but not so detailed that it prescribes specific code.

### Required Sections

**Purpose and success criteria.** Success criteria must be concrete and testable — a planner should be able to write a pass/fail check for each one. "User can select a model" is testable. "Performance is good" is not.

**Architecture and approach.** Rationale for why this approach over alternatives. Include rejected alternatives and why — this prevents re-litigating settled decisions.

**Components and data flow.** For each component or subsystem:
- Responsibility, data in (exact source — API type, signal, message type), data out (format, destination)
- Connection to neighbors (call, message, signal, shared state)
- Failure modes: specific failure → specific response (not "handle errors gracefully")
- Boundary conditions: empty state, maximum load, saturation, concurrent access, dependency unavailability

**Cross-boundary protocols.** For every boundary where two systems communicate (IPC, network, postMessage, USB, SPI, module boundaries), define the typed interface or message set, data flow direction, error signaling, and behavior when one side is unavailable. Can be folded into component descriptions for small specs.

**Integration: how the feature becomes reachable.** Which existing entry points need modification so a user can invoke the feature. A feature that works in isolation but isn't wired in is not a feature.

**Error handling.** System-level failures beyond per-component: connection drops, process crashes, power loss, malformed input at boundaries. For each: detection, response, recovery (or explicit statement that recovery is not possible).

**Edge cases.** Enumerate specific scenarios at behavioral boundaries. For each: trigger and correct behavior.

**Acceptance criteria and metrics.** For any quantitative claim (performance, accuracy, latency, signal quality): the formula or measurement method, the acceptability threshold (or "TBD — criteria: [what's needed]"), and the data source.

**Testing strategy.** What kinds of tests, what to cover, critical scenarios. Not test code, but enough for a planner to know what assertions matter.

**Prerequisites / Required Access.** Everything an autonomous stage needs that only the user provides — credentials, secrets, authenticated CLIs (`glab`/`gh`/cloud login), deploy/publish targets, accounts, paid resources — as surfaced in Phase 5. For each: *what* it is, *which stage* needs it, *where the value lives* (env var name, secret-file path, pre-authed CLI — **never the secret value itself**), and *the check* a stage runs to confirm it's present before relying on it (e.g. `glab auth status`). If the feature needs none, write "None." This section is what lets the pipeline run unattended: anything missing here will fail a downstream stage rather than pause for a question.

**Validation protocol.** How to verify the implementation works after it's built — consumed by the *validate stage agent*, not the planner. If a validation or deploy command depends on access listed above, reference it by name (env var / pre-authed CLI) so the validate stage knows the dependency rather than guessing. For each validation step: the exact command to run (copy-pasteable, not "run the tests"), what success looks like (exit code 0, specific output pattern, file content), and how to interpret failure output for diagnosis. If the only validation is running the test suite, write the literal command and what a passing run looks like. If the feature cannot be validated with executable commands (pure documentation, config-only changes, refactoring with no behavioral change), write "N/A — [reason]." The validate stage executes this protocol literally — concrete commands only.

**Visual structure (UI-aware only).** Layout skeleton: what goes where, spatial relationships, grouping, hierarchy. Key component states: empty, loading, error, populated, overflow. Reference UI if one exists. Not CSS or pixels — enough for a planner to know spatial intent without guessing.

**Out of scope.** What is excluded and why. If deferred, to which phase.

### Depth Calibration

Calibrate depth to complexity. A two-file feature needs less protocol specification than a multi-layer system. When in doubt, go deeper — an under-specified spec wastes implementer time and produces bugs, which is far more expensive than over-specifying.

The spec does NOT include phase breakdowns or implementation ordering. If the scope warrants phasing, that happens in a separate roadmap brainstorm after this spec passes review.

Write the finished spec to the path the orchestrator assigned (recorded in the pipeline's `state.json` `artifacts`).

## User Approval Gate

**After writing the spec, you MUST ask the user to review it before completing.** Mandatory — never finish without explicit user approval. Ask the user to read the spec and either confirm it's good to move forward, or give feedback; revise and re-ask until they approve. When approved, the stage is complete: you (the orchestrator) record it in `state.json` (`done[]`, `phase`, `artifacts`) and advance. **This is the only `state.json` write for the stage — don't update it mid-conversation or journal the discussion into it; the design lives in the spec.**
