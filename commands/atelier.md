---
description: Run, resume, restart, or abort an Atelier pipeline. Pass a task description for a new pipeline, or "resume <description>" / "restart <stage>" / "start from <stage> <desc>" / "status" / "abort".
argument-hint: <task description | resume <desc> | restart <stage> | start from <stage> <desc> | status | abort>
---

You are the Atelier dispatcher. `$ARGUMENTS` contains the user's input.

## Step 1 — Gather context

Use `Bash` to enumerate existing pipelines: `ls -1 .atelier/pipelines/ 2>/dev/null` and for each one, `jq -r '"\(.id)\t\(.prompt)\t\(.status)\t\(.currentStage)\t\(.type)\t\(.expectedMode // "")\t\(.sourceSessionId // "")"' .atelier/pipelines/<id>/pipeline-state.json`. Keep this list mentally — you'll fuzzy-match against `prompt` for resume/restart.

The pipeline owned by THIS Claude Code session is the (at-most-one) row where `sourceSessionId == $CLAUDE_SESSION_ID AND status == "running"`. That's the "active" pipeline for this session. Other sessions may concurrently own their own pipelines on the same workspace; they appear in the list but are not yours to act on by default.

**Active-pipeline guard.** If THIS session owns a pipeline AND its `expectedMode == "interactive"` AND `$ARGUMENTS` looks like a new task (not "resume", "status", "abort", or "redirect"), this is most likely the user accidentally typing while an interactive stage is mid-conversation. Use AskUserQuestion to confirm before starting a new pipeline:
- header: `Active pipeline`
- question: "An interactive Atelier stage (`<currentStage>`) is in flight. Start a NEW pipeline anyway, or treat your input as a redirect/cancel?"
- options: `New pipeline (abort current)`, `Redirect`, `Cancel`
- on "New pipeline": run `scripts/abort.sh <active-id>` first, then proceed with the new-task branch.
- on "Redirect": route to the **redirect** branch.
- on "Cancel": end turn with no action.

## Step 2 — Classify intent

Decide which branch `$ARGUMENTS` falls into. Use the following rules in order:

- **Empty $ARGUMENTS** → "new task" branch, but first AskUserQuestion: "What would you like to build?" (header: `Task`, options: `Custom`, `Cancel`).
- Starts with "status", "list", "show pipelines", just "status" → **status** branch.
- Starts with "abort", "cancel", "stop pipeline" → **abort** branch.
- Starts with "resume", "continue", "pick up" → **resume** branch.
- Contains "back to", "restart from", "redo <stage>", "go back to" → **restart-from** branch.
- Starts with "start from", "start at", "begin at", "begin from", or contains an explicit "from <stage>" / "at <stage>" hint paired with a task description → **start-at-stage** branch. Heuristic: the user names a pipeline stage (e.g. "planning", "write plan", "e2e", "implement", "review") AND provides a new task description. This creates a NEW pipeline that skips earlier stages — distinct from `restart-from` which targets an existing pipeline.
- Otherwise → **new task** branch (treat the whole $ARGUMENTS as the task description).

If the intent is ambiguous, use AskUserQuestion with the two possibilities as options before branching.

## Step 3 — Execute the branch

### New task

1. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/start-pipeline.sh "<the task description>"` — capture the pipeline id from stdout. The script requires `$CLAUDE_SESSION_ID` (Claude Code sets this).
2. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-topologies.sh` — parse the output (one `name<TAB>description` per line).
3. AskUserQuestion #1 — header `Pipeline`, question "Which pipeline type fits this task?", options dynamically built: one option per topology with `label = description`, `value = name`. Up to 4 options.
4. AskUserQuestion #2 — header `Worktree`, question "Run in a separate git worktree, or in the current tree?", options: `worktree` ("Isolate work in a git worktree"), `in-tree` ("Work in the current branch").
5. Call `mcp__atelier__atelier_signal` with `{type:"stage_complete", pipelineId:"<id>", pipelineType:<chosen>, worktreeChoice:<chosen>}`. **Do NOT include `verdict`.** Classify carries CONFIGURATION, not COMPLETION — including `verdict:"done"` would set `lastVerdict="done"` on a state with `currentStage=null`, leaving stale verdict context. STOP YOUR TURN.

### Resume

1. From the pipeline list, fuzzy-match $ARGUMENTS (minus "resume" prefix) against each `prompt`.
2. If exactly one match → use it. If multiple matches → AskUserQuestion with the candidate prompts. If zero matches → tell the user "No matching pipeline." and end turn.
3. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh <pipeline-id>`. The script requires `$CLAUDE_SESSION_ID` and stamps the resumed pipeline's `sourceSessionId` to this session — transferring ownership.
4. Print "Resumed pipeline `<id>` at stage `<stage>` — re-dispatching now." Then **end your turn. DO NOT call `atelier_signal`.** `resume.sh` has set `status=running` and refreshed `sourceSessionId`; the Stop hook will fire at end-of-turn, read `lastVerdict` as-is (typically `null` because the crashed stage never signaled), and re-dispatch the same stage. The re-dispatched stage agent will read `progress.md` and continue from where it left off.

### Restart from stage

1. Parse the stage name from $ARGUMENTS (the word after "back to" / "restart from" / "redo").
2. If this session owns no pipeline, ask the user to specify which pipeline (via AskUserQuestion listing recent pipelines).
3. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/restart-stage.sh <pipeline-id> <stage>`. The script requires `$CLAUDE_SESSION_ID` and transfers ownership to this session.
4. Print "Restarting pipeline `<id>` at stage `<stage>`." Then **end your turn. DO NOT call `atelier_signal`.** `restart-stage.sh` already cleared `lastVerdict` and set `currentStage`; the Stop hook will fire at end-of-turn and dispatch the target stage fresh.

### Start at stage

Creates a pipeline whose first dispatched stage is the one the user named — useful when prior conversation already supplies the artifacts an earlier stage would have produced (e.g. a written plan, a finished spec, or a review report). The task description in $ARGUMENTS should be self-contained: the chosen stage's skill will read it as the pipeline prompt.

1. Strip the leading directive ("start from", "start at", "begin at", "begin from") from $ARGUMENTS. What remains is the task description — keep the whole thing including any stage hint, since the stage's skill will benefit from the full context.
2. Infer a candidate stage from the user's wording: e.g. "planning" / "write plan" → `write_plan`, "e2e" / "end-to-end tests" → `write_e2e_plan` (or `e2e` if the plan exists), "implement" → `implement`, "review" → the appropriate `review_*` stage, "spec" / "brainstorm" → `brainstorm`. If you cannot infer, leave the candidate empty.
3. **Detect existing-pipeline reference.** Scan $ARGUMENTS for a path containing `.atelier/pipelines/<dir-name>` (either a directory, or a file like `plan.md` / `spec.md` inside one). If found, that's the **adopt target** — the new pipeline should LIVE in that dir so its state lands next to the existing artifacts. Otherwise the new pipeline gets a fresh dir.
   - If an adopt target is found AND the dir lacks `pipeline-state.json`, run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/attach-pipeline.sh "<dir-path>" "<task description>"` — capture the pipeline id.
   - If an adopt target is found AND the dir already has `pipeline-state.json`, this is a managed pipeline. AskUserQuestion to choose:
     - option 1, label `Restart from <inferred-stage>` (Recommended) — the user already named the stage in $ARGUMENTS; on selection, run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/restart-stage.sh <pipeline-id> <inferred-stage>` and end your turn (do NOT signal — restart-stage.sh writes state directly and the Stop hook routes from there).
     - option 2, label `Resume current stage` — on selection, run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/resume.sh <pipeline-id>` and end your turn.
     - option 3, label `New sibling pipeline` — fall through to the no-adopt-target branch (start-pipeline.sh).
     If you have NO confidently inferred stage, drop option 1 and present only Resume / New sibling.
   - Otherwise (no adopt target), run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/start-pipeline.sh "<task description>"` — capture the pipeline id.

   **Stop here** if you took the Restart-from or Resume sub-branches above — those scripts mutate state directly and the Stop hook will dispatch the chosen stage. Continue to step 4 only for the attach-pipeline.sh and start-pipeline.sh paths (which leave the pipeline at the classify gate, awaiting topology + worktree + currentStage via signal).
4. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-topologies.sh` — parse one `name<TAB>description` per line.
5. AskUserQuestion #1 — header `Pipeline`, question "Which pipeline type fits this task?", options dynamically built from topologies (`label = description`, value = name). Pick a sensible default ordering based on the inferred stage (e.g. if stage involves "e2e" prefer `feature`/`epic`; if "plan" prefer `feature`/`plan`).
6. Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-stages.sh <chosen-topology>` — parse one `name<TAB>skill<TAB>mode` per line.
7. AskUserQuestion #2 — header `Stage`, question "Which stage should the pipeline start at?", options built from that topology's stages (up to 4 — if more, surface the most plausible 3 plus an "Other" by listing the inferred candidate first, then nearby stages). If you have a confident inferred candidate, list it first and append "(Recommended)" to its label.
8. AskUserQuestion #3 — header `Worktree`, question "Run in a separate git worktree, or in the current tree?", options: `worktree` ("Isolate work in a git worktree"), `in-tree` ("Work in the current branch").
9. Call `mcp__atelier__atelier_signal` with `{type:"stage_complete", pipelineId:"<id>", pipelineType:<chosen>, worktreeChoice:<chosen>, currentStage:<chosen-stage>}`. **Do NOT include `verdict`.** STOP YOUR TURN.

### Status

Read all `pipeline-state.json` files; print a markdown table: `| id | type | status | currentStage | prompt | sourceSessionId | mine? |` where `mine?` is `(mine)` when `sourceSessionId == $CLAUDE_SESSION_ID` and empty otherwise. This makes cross-session pipelines visible without confusing them with this session's own work. End turn — DO NOT signal.

### Abort

Determine pipeline id (this session's owned pipeline if present, else AskUserQuestion). Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/abort.sh <pipeline-id>`. End turn — no signal.

### Redirect

For inline `/atelier <guidance>` issued mid-pipeline (active stage running, user wants to adjust direction):

1. Read state.expectedMode and currentStage from this session's owned pipeline's `pipeline-state.json`.
2. Update state with `pendingRedirect` = `<guidance>` via `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/redirect.sh "<guidance>"`. The script resolves the owned pipeline via `$CLAUDE_SESSION_ID`; do NOT pass a pipeline id.
3. Path A (preferred, UX improvement): try SendMessage to the active subagent session with the guidance.
4. Path B (fallback, sufficient): instruct user that the redirect is queued and will be consumed on next stage dispatch via the RESUMING block in compile-prompt.sh. End your turn — DO NOT signal.

## Important

- **Only the "new task" and "start-at-stage" branches signal.** They call `atelier_signal` with an explicit `pipelineId` because the classify-stage output (pipelineType, worktreeChoice, and for start-at-stage also currentStage) needs to be persisted into top-level state fields via the MCP tool. The MCP signal handler only honors `pipelineType` / `worktreeChoice` / `currentStage` when `state.currentStage == null` (the classify gate); subsequent signals can't relocate the pipeline.
- **Resume and restart-from must NOT signal.** Their helper scripts mutate state directly (set `status=running`, refresh `sourceSessionId`, optionally clear `lastVerdict` / set `currentStage`); the Stop hook fires at end-of-turn and routes from the resulting state. Signaling `verdict=done` from resume would incorrectly advance past a crashed stage.
- For read-only branches (status, abort, redirect), do NOT signal — just perform the operation and end your turn.
- Never decide the next stage yourself. Routing is owned by the Stop hook.
- **One pipeline per session.** A single Claude Code session drives exactly one pipeline forward at a time. Multiple sessions can each own their own pipeline simultaneously on the same workspace; signals carry explicit `pipelineId` to keep routing unambiguous.
