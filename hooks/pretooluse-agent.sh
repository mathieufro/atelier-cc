#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Agent" ] || exit 0

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
