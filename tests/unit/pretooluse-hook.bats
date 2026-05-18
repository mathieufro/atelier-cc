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

@test "non-owner session, single running pipeline, genuine dispatch: ownership fallback RESOLVES and rewrites (no sentinel passthrough, no deny-loop)" {
  # sess-Other doesn't own it, but exactly one pipeline is running in TMP →
  # deterministic fallback adopts it; a real atelier dispatch must be compiled,
  # never silently pass the literal sentinel to a subagent.
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-Other\",\"tool_input\":{\"subagent_type\":\"atelier:atelier-stage-worker\",\"description\":\"atelier:write_plan\",\"prompt\":\"<MARKER:next-stage>\"}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.subagent_type)" = "atelier:atelier-stage-worker" ]
  [[ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.prompt)" != *"<MARKER:next-stage>"* ]]
}

@test "non-owner session helper subagent (not a dispatch) is NEVER hijacked, even with a running pipeline" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-Other\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"description\":\"research X\",\"prompt\":\"survey libs\"}}")"
  [ -z "$out" ]
}

@test "Agent with the next-stage sentinel and a valid owned autonomous pipeline: still rewrites" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{\"subagent_type\":\"x\",\"prompt\":\"<MARKER:next-stage>\"}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.subagent_type)" = "atelier:atelier-stage-worker" ]
  [[ "$(echo "$out" | jq -r .hookSpecificOutput.updatedInput.prompt)" != *"<MARKER:next-stage>"* ]]
}

@test "Agent WITHOUT the marker and no owned pipeline: still silently passes through (helper subagents unaffected)" {
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-Other\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"prompt\":\"go research X\"}}")"
  [ -z "$out" ]
}

@test "Agent tool in interactive stage with no stage-worker delegation: passes through" {
  ps_update "$TMP" "$PID" '.expectedMode = "interactive"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$out" ]
}

@test "interactive stage: delegating to atelier:atelier-stage-worker is DENIED (no ping-pong)" {
  ps_update "$TMP" "$PID" '.expectedMode = "interactive" | .currentStage = "task_brainstorm"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{\"subagent_type\":\"atelier:atelier-stage-worker\",\"description\":\"atelier:task_brainstorm continuation\",\"prompt\":\"x\"}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "deny" ]
  reason="$(echo "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)"
  [[ "$reason" == *"task_brainstorm"* ]]
  [[ "$reason" == *"INTERACTIVE"* ]]
  [[ "$reason" == *"conversation"* ]]
  [[ "$reason" == *"end your turn"* ]]
  [[ "$reason" != *"Ask the user directly with AskUserQuestion"* ]]
}

@test "interactive stage: Agent with atelier:* description is DENIED even if subagent_type differs" {
  ps_update "$TMP" "$PID" '.expectedMode = "interactive" | .currentStage = "brainstorm"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"description\":\"atelier:brainstorm\",\"prompt\":\"x\"}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "deny" ]
}

@test "interactive stage: unrelated helper subagent passes through (not over-restricted)" {
  ps_update "$TMP" "$PID" '.expectedMode = "interactive" | .currentStage = "brainstorm"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{\"subagent_type\":\"general-purpose\",\"description\":\"research auth libraries\",\"prompt\":\"survey\"}}")"
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

@test "terminal pipeline (stuck): not resolvable → hook no-ops (loop-safe: Stop/SubagentStop inert on stuck)" {
  ps_update "$TMP" "$PID" '.status = "stuck" | .error = "x"'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ -z "$out" ]
}

@test "dispatch budget: under cap increments launchCount and rewrites normally" {
  ps_update "$TMP" "$PID" '.stages = [{"id":"w1","stage":"write_plan","status":"running"}]'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(jq -r '.stages[-1].launchCount' ".atelier/pipelines/$PID/pipeline-state.json")" = "1" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

@test "dispatch budget: exceeding cap with no sessionId/verdict → pipeline stuck + deny (deterministic loop bound)" {
  ps_update "$TMP" "$PID" '.stages = [{"id":"w1","stage":"write_plan","status":"running","launchCount":3}]'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "deny" ]
  reason="$(echo "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)"
  [[ "$reason" == *"stuck"* ]]
  [[ "$reason" == *"never ran or signalled"* ]]
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"dispatch budget exhausted"* ]]
}

@test "dispatch budget: a stage row that already recorded a sessionId never trips (healthy re-runs allowed)" {
  ps_update "$TMP" "$PID" '.stages = [{"id":"w1","stage":"write_plan","status":"running","launchCount":9,"sessionId":"sub-1"}]'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

@test "dispatch budget: skipped when last row is not the running current stage (no false stuck)" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" |
    .stages = [{"id":"r1","stage":"review_plan","status":"completed","launchCount":99}]'
  out="$(drive "{\"tool_name\":\"Agent\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\",\"tool_input\":{}}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.permissionDecision)" = "allow" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}
