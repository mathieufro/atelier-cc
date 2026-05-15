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
[ "$mode" = "autonomous" ] || exit 0

stage="$(jq -r .currentStage "$sp")"
model="$(jq -r '.expectedModel // empty' "$sp")"

compiled="$("$ROOT/scripts/compile-prompt.sh" "$pid" "$stage")"

# Persist the compiled prompt and record its path on the stage row. The path
# doubles as a "main agent actually launched the Agent tool" marker: when Stop
# fires later, an in-flight running row with no compiledPromptPath means the
# dispatch was emitted but the main agent never called Agent (e.g. it got
# confused by the just-completed subagent's terminal text and stopped without
# acting on the block reason). Stop uses that signal to re-emit the dispatch.
compiled_dir="$wsp/.atelier/pipelines/$pid/.compiled"
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
