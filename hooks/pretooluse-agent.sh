#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Agent" ] || exit 0

# Reverted (was: a marker-deny that returned permissionDecision:deny whenever
# the session didn't own a pipeline and the Agent prompt contained the
# next-stage sentinel). That was actively harmful: (1) it substring-matched the
# sentinel in ANY Agent/Task prompt and blocked unrelated subagents in sessions
# that don't own a pipeline; (2) per the Claude Code hook contract a PreToolUse
# deny whose condition doesn't change re-fires on every re-dispatch, so when
# ownership resolution itself failed the deny looped unbreakably (dispatch →
# deny → stop → resume → deny …). Restoring the prior silent pass-through: if we
# can't resolve+rewrite, do nothing (the underlying fix is ownership resolution,
# not a deny that loops).
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd"
wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$session_id")"
[ -n "$pid" ] || exit 0

sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || exit 0
mode="$(jq -r '.expectedMode // empty' "$sp")"
stage="$(jq -r '.currentStage // empty' "$sp")"
status="$(jq -r '.status // empty' "$sp")"
owner_sid="$(jq -r '.sourceSessionId // empty' "$sp")"

# Ownership-fallback safety gate. If this pipeline was resolved by the
# single-running-in-workspace fallback (sourceSessionId != this session — see
# find_owned_pipeline), only intercept GENUINE atelier dispatch calls. A
# non-owning session in this workspace must be able to spawn its own helper
# subagents without this hook hijacking them into a stage worker / denying
# them. For the stamped owner, the existing contract holds unchanged (during
# an autonomous stage the main agent's Agent call IS the dispatch). The
# per-stage dispatch budget below is the hard backstop for any mis-resolution.
if [ "$owner_sid" != "$session_id" ]; then
  _sub="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')"
  _desc="$(printf '%s' "$input" | jq -r '.tool_input.description // ""')"
  _pr="$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""')"
  _is_dispatch=0
  [ "$_sub" = "atelier:atelier-stage-worker" ] && _is_dispatch=1
  [[ "$_desc" == atelier:* ]] && _is_dispatch=1
  case "$_pr" in *'<MARKER:next-stage>'*) _is_dispatch=1 ;; esac
  [ "$_is_dispatch" = "1" ] || exit 0
fi

# (No standalone terminal-status guard: find_owned_pipeline only ever resolves
# a RUNNING pipeline, so a parked one already yields empty pid → this hook
# exits above. That is loop-safe because Stop/SubagentStop early-exit on a
# non-running pipeline, so nothing re-feeds a dispatch directive. The
# meaningful terminal signal is the dispatch budget below, which flips the
# pipeline to `stuck` and denies in the same invocation.)

if [ "$mode" != "autonomous" ]; then
  # Interactive stage (or pre-classify). The MAIN agent owns the user
  # conversation and MUST run the stage itself (AskUserQuestion → work →
  # artifact → atelier_signal → stop). Delegating an interactive stage to a
  # pipeline stage-worker subagent makes the main agent ping-pong with a
  # background agent and reach for SendMessage (unavailable) — wasteful and a
  # frequent wedge. Hard-deny that specific delegation; allow unrelated helper
  # subagents (research, parallel exploration, etc.) to pass through.
  sub="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // ""')"
  desc="$(printf '%s' "$input" | jq -r '.tool_input.description // ""')"
  if [ "$sub" = "atelier:atelier-stage-worker" ] || [[ "$desc" == atelier:* ]]; then
    jq -nc --arg s "${stage:-this}" '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: ("\($s) is an INTERACTIVE stage — you, the main agent, must run it YOURSELF as a normal conversation with the user. Do NOT spawn a stage-worker subagent and do NOT use SendMessage. Ask one question at a time as plain conversational text (recommendation + rationale + options per the stage skill), then end your turn — control yields cleanly to the user and their reply comes back as the next message; you do NOT need AskUserQuestion to pause. Do the work, write the artifact, then call mcp__atelier__atelier_signal.")
      }
    }'
  fi
  exit 0
fi

model="$(jq -r '.expectedModel // empty' "$sp")"

# ── Deterministic per-stage-row dispatch budget ──────────────────────────────
# This hook is the SINGLE chokepoint every stage-worker launch passes through.
# Count launches on the current running stage row. If that row is launched more
# than the cap WITHOUT ever recording a sessionId or verdict (the worker never
# actually ran or never signalled — the unbounded-loop class: no-ownership-now-
# resolved, contaminated terminal text, never-signalled, partial-no-resignal),
# the dispatch is structurally looping. Mark the pipeline `stuck` and deny.
# Stop/SubagentStop then early-exit on `stuck` (no re-emit) so it CANNOT loop
# past the cap — a hard, deterministic bound. `/atelier resume` demotes the row
# and routing appends a fresh row (launchCount unset → 0), resetting the budget.
LAUNCH_CAP="${ATELIER_DISPATCH_CAP:-3}"
lc="$(jq -r --arg st "$stage" '
  (.stages // []) | (last // {})
  | if (.stage == $st and .status == "running") then (.launchCount // 0) else -1 end' "$sp")"
if [ -n "$lc" ] && [ "$lc" -ge 0 ] 2>/dev/null; then
  newlc=$((lc + 1))
  had_run="$(jq -r '(.stages // []) | (last // {}) | (if ((.sessionId != null) or (.verdict != null)) then "yes" else "no" end)' "$sp")"
  if [ "$newlc" -gt "$LAUNCH_CAP" ] && [ "$had_run" = "no" ]; then
    diag="dispatch budget exhausted: stage \"$stage\" was launched $newlc times without the worker ever running or signalling — paused to prevent an infinite re-dispatch loop"
    ps_update "$wsp" "$pid" \
      '.status = "stuck" | .error = $e |
       (.stages |= (.[:-1] + [.[-1] + {status:"stuck", error:$e, launchCount:$n}]))' \
      --arg e "$diag" --argjson n "$newlc"
    jq -nc --arg s "$stage" --argjson n "$newlc" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:("Atelier is now `stuck`: stage \($s) was dispatched \($n) times and the worker never ran or signalled (a structural loop). The pipeline will NOT re-dispatch. Do NOT retry this Agent call. Investigate why the \($s) worker never signalled `atelier_signal` (it may have emitted orchestration text instead of doing the task, or could not start), then run `/atelier resume <task>` to reset the budget and retry.")}}'
    exit 0
  fi
  ps_update "$wsp" "$pid" \
    '.stages |= (.[:-1] + [.[-1] + {launchCount:$n}])' --argjson n "$newlc"
fi

compiled="$("$ROOT/scripts/compile-prompt.sh" "$pid" "$stage")"

# Persist the compiled prompt and record its path on the stage row. The path
# doubles as a "main agent actually launched the Agent tool" marker: when Stop
# fires later, an in-flight running row with no compiledPromptPath means the
# dispatch was emitted but the main agent never called Agent (e.g. it got
# confused by the just-completed subagent's terminal text and stopped without
# acting on the block reason). Stop uses that signal to re-emit the dispatch.
# Transient scaffolding: consumed immediately (passed via updatedInput.prompt
# below). Afterward only compiledPromptPath's *presence in state* matters as the
# "main agent actually launched Agent" marker — the file is never stat'd or
# re-read. Keep it OUT of the workspace so .atelier/pipelines/<id>/ doesn't
# accrue dead .compiled/ prompt dumps that pollute the user's repo.
compiled_dir="${TMPDIR:-/tmp}/atelier-cc/$pid/compiled"
mkdir -p "$compiled_dir"
compiled_path="$compiled_dir/$(epoch_ms)-${stage}.md"
printf '%s' "$compiled" > "$compiled_path"
ps_update "$wsp" "$pid" \
  '.stages |= (if (length > 0 and .[-1].status == "running") then .[:-1] + [.[-1] + {compiledPromptPath: $p}] else . end)' \
  --arg p "$compiled_path"

jq -nc \
  --arg sub "atelier:atelier-stage-worker" \
  --arg desc "atelier:$stage" \
  --arg prompt "$compiled" \
  --arg model "$model" \
  '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: (
        {subagent_type: $sub, description: $desc, prompt: $prompt}
        + (if $model == "" then {} else {model: $model} end)
      )
    }
  }'
