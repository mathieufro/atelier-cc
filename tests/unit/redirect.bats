#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'task')"
  ps_update "$TMP" "$PID" \
    '.currentStage = "implement" | .expectedMode = "autonomous" | .expectedSubagent = "atelier:atelier-stage-worker" |
     .stages = [{id:"i1",stage:"implement",status:"running",sessionId:"abc123",startedAt:0}]'
}
teardown() {
  rm -rf "$TMP"
  restore_skill implementing-plans
}

@test "redirect.sh writes pendingRedirect and echoes target sessionId" {
  out="$("$ATELIER_CC_ROOT/scripts/redirect.sh" 'use approach X instead of Y')"
  [ "$out" = "abc123" ]
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r '.pendingRedirect.guidance')" = "use approach X instead of Y" ]
  [ "$(echo "$state" | jq -r '.pendingRedirect.targetSessionId')" = "abc123" ]
  [ "$(echo "$state" | jq -r '.pendingRedirect.createdAt | type')" = "number" ]
}

@test "redirect.sh echoes empty when no current sessionId" {
  ps_update "$TMP" "$PID" '.stages = [{id:"i1",stage:"implement",status:"running",startedAt:0,sessionId:null}]'
  out="$("$ATELIER_CC_ROOT/scripts/redirect.sh" 'do X')"
  [ -z "$out" ]
  [ "$(jq -r '.pendingRedirect.targetSessionId' ".atelier/pipelines/$PID/pipeline-state.json")" = "null" ]
}

@test "redirect.sh dies without guidance" {
  run "$ATELIER_CC_ROOT/scripts/redirect.sh"
  [ "$status" -ne 0 ]
}

@test "redirect.sh escapes quotes and special chars" {
  "$ATELIER_CC_ROOT/scripts/redirect.sh" 'use "JSON quoted" instead of `backticks`'
  [ "$(jq -r '.pendingRedirect.guidance' ".atelier/pipelines/$PID/pipeline-state.json")" = 'use "JSON quoted" instead of `backticks`' ]
}

@test "compile-prompt prepends USER REDIRECT block and clears pendingRedirect" {
  bash "$ATELIER_CC_ROOT/scripts/redirect.sh" 'switch to async pattern'
  backup_skill implementing-plans
  printf '%s\n' '---' 'name: implementing-plans' '---' 'body' \
    > "$ATELIER_CC_ROOT/skills/implementing-plans/SKILL.md"
  ps_update "$TMP" "$PID" '.expectedSkill = "implementing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "implement")"
  [[ "$output" == *"USER REDIRECT"* ]]
  [[ "$output" == *"switch to async pattern"* ]]
  [ "$(jq -r .pendingRedirect ".atelier/pipelines/$PID/pipeline-state.json")" = "null" ]
}

@test "subagent-stop does not mark stuck when pendingRedirect is set and no verdict" {
  bash "$ATELIER_CC_ROOT/scripts/redirect.sh" 'do Y'
  ps_update "$TMP" "$PID" '.lastVerdict = null'
  printf '{"agent_type":"atelier:atelier-stage-worker","agent_id":"abc123","cwd":"%s","session_id":"sess-t"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].error // empty')" != "subagent terminated without signaling" ]
}
