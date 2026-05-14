#!/usr/bin/env bats

@test "PreToolUse output uses hookSpecificOutput.updatedInput exactly" {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export CLAUDE_SESSION_ID="sess-t"
  PID="$($BATS_TEST_DIRNAME/../../scripts/start-pipeline.sh 'x')"
  ps_update "$TMP" "$PID" '.currentStage = "implement" | .expectedSkill = "implementing-plans" |
    .expectedMode = "autonomous" | .expectedSubagent = "atelier:atelier-stage-worker"'
  SKILL_DIR="$BATS_TEST_DIRNAME/../../skills/implementing-plans"
  PRESYNCED=false
  if [ -f "$SKILL_DIR/SKILL.md" ]; then
    PRESYNCED=true
  else
    mkdir -p "$SKILL_DIR"
    printf '%s\n' '---' 'name: implementing-plans' '---' 'body' > "$SKILL_DIR/SKILL.md"
  fi
  out="$(printf '{"tool_name":"Agent","cwd":"%s","session_id":"sess-t","tool_input":{}}' "$TMP" \
    | "$BATS_TEST_DIRNAME/../../hooks/pretooluse-agent.sh")"
  jq -e '.hookSpecificOutput.updatedInput.subagent_type' <<<"$out" >/dev/null
  jq -e '.hookSpecificOutput.updatedInput.prompt' <<<"$out" >/dev/null
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<<"$out")" = "PreToolUse" ]
  [ "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")" = "allow" ]
  rm -rf "$TMP"
  [ "$PRESYNCED" = "true" ] || rm -rf "$SKILL_DIR"
}
