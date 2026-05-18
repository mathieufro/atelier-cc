#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Agent" ] || exit 0

# `<MARKER:next-stage>` is an INTERNAL sentinel: the orchestrator's dispatch
# directive tells the main agent to call Agent with prompt='<MARKER:next-stage>'
# expecting THIS hook to replace it with the compiled stage prompt. If we ever
# let the literal sentinel reach a subagent, that subagent has no real task —
# it produces nothing, SubagentStop sees no verdict, the stage is re-dispatched,
# and the pipeline spins forever ("red dot"). So whenever we would bail WITHOUT
# rewriting, deny instead — never pass the placeholder through.
marker=0
case "$(printf '%s' "$input" | jq -r '.tool_input.prompt // ""')" in
  *'<MARKER:next-stage>'*) marker=1 ;;
esac
_deny_unresolved() {
  [ "$marker" = "1" ] || exit 0
  jq -nc --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || _deny_unresolved "Atelier could not resolve a session id for this Agent dispatch, so the '<MARKER:next-stage>' placeholder cannot be compiled into a real stage prompt. Do NOT retry this Agent call. Run \`/atelier status\` then \`/atelier resume <task>\` to re-attach."
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd"
wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$session_id")"
[ -n "$pid" ] || _deny_unresolved "This Claude Code session does not own an active Atelier pipeline in $wsp. The pipeline's sourceSessionId was stamped by a different session — common when it was started/seeded in another window or 'from specs', or when this window's working directory differs from the pipeline workspace. The orchestrator cannot compile the real stage prompt, so the '<MARKER:next-stage>' placeholder must NOT be sent to a subagent (doing so spins the pipeline forever). Do NOT retry this Agent call. Run \`/atelier resume <task description>\` from THIS session (it re-stamps sourceSessionId and re-dispatches), or restart Claude Code in the pipeline's workspace."

sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || _deny_unresolved "Atelier resolved pipeline '$pid' but its state file is missing at $sp, so the stage prompt cannot be compiled. Do NOT retry this Agent call with the placeholder. Run \`/atelier status\` to inspect, or \`/atelier resume <task>\`."
mode="$(jq -r '.expectedMode // empty' "$sp")"
stage="$(jq -r '.currentStage // empty' "$sp")"

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
