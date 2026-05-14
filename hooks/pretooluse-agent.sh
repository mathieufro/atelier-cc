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
