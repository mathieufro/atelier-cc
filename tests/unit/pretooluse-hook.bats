#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  backup_skill writing-plans
  cat > "$ATELIER_CC_ROOT/skills/writing-plans/SKILL.md" <<EOF2
---
name: writing-plans
---
Body text
EOF2
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'task description')"
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans" |
    .expectedMode = "autonomous" | .expectedSubagent = "atelier:atelier-stage-worker"'
}
teardown() {
  rm -rf "$TMP"
  restore_skill writing-plans
}

drive() {
  printf '%s' "$1" | "$ATELIER_CC_ROOT/hooks/pretooluse-agent.sh"
}

@test "non-Agent tool: exits with no output" {
  out="$(drive "{\"tool_name\":\"Read\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$out" ]
}

@test "Agent tool with no owned pipeline: passes through" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-Other\"}")"
  [ -z "$out" ]
}

@test "Agent tool in interactive stage: passes through" {
  ps_update "$TMP" "$PID" '.expectedMode = "interactive"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$out" ]
}

@test "Agent tool in autonomous stage: rewrites subagent_type and prompt" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"<MARKER:next-stage>\"}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.subagent_type)" = "atelier:atelier-stage-worker" ]
  prompt="$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.prompt)"
  [[ "$prompt" == *"# Stage: write_plan"* ]]
  [[ "$prompt" == *"Body text"* ]]
  [[ "$prompt" == *"atelier_signal"* ]]
}

@test "description field formatted as atelier:<stage>" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.description)" = "atelier:write_plan" ]
}

@test "expectedModel propagates when set" {
  ps_update "$TMP" "$PID" '.expectedModel = "claude-sonnet-4-6"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.model)" = "claude-sonnet-4-6" ]
}
