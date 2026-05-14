#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"
  cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'foo')"
  ps_update "$TMP" "$PID" '.status = "idle"'
}
teardown() { rm -rf "$TMP"; }

@test "resume.sh restores running status and refreshes sourceSessionId" {
  CLAUDE_CODE_SESSION_ID="sess-resumer" "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
  [ "$(jq -r .sourceSessionId ".atelier/pipelines/$PID/pipeline-state.json")" = "sess-resumer" ]
  [ ! -f .atelier/active-pipeline ]
}

@test "resume.sh fails for unknown pipeline" {
  run "$ATELIER_CC_ROOT/scripts/resume.sh" "nonexistent-pid"
  [ "$status" -ne 0 ]
}

@test "resume.sh demotes dangling running stage row (unwedges Stop hook guard)" {
  # Drift scenario: pipeline is idle but trailing stage row is still "running"
  # (subagent died without signaling, manual edit, race with abort, etc.).
  # Without demotion, the Stop hook's stage-in-progress guard short-circuits and
  # the pipeline can never re-dispatch.
  ps_update "$TMP" "$PID" \
    '.currentStage = "implement" | .lastVerdict = null |
     .stages = [{"id":"s1","stage":"implement","status":"running"}]'
  CLAUDE_CODE_SESSION_ID="sess-resumer" "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "idle" ]
  [ "$(echo "$state" | jq -r '.stages[-1].interrupted')" = "true" ]
}

@test "resume.sh demotes dangling stuck stage row (opts back into dispatch)" {
  # subagent-stop.sh marks a crashed stage row stuck. Routing pauses on
  # last_status=stuck to avoid auto-retry loops on deterministic crashes —
  # resume.sh is the explicit retry signal, so it must demote stuck → idle.
  ps_update "$TMP" "$PID" \
    '.currentStage = "implement" | .lastVerdict = null |
     .stages = [{"id":"s1","stage":"implement","status":"stuck","error":"subagent terminated without signaling"}]'
  CLAUDE_CODE_SESSION_ID="sess-resumer" "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "idle" ]
  [ "$(echo "$state" | jq -r '.stages[-1].interrupted')" = "true" ]
}

@test "resume.sh leaves completed and idle stage rows untouched" {
  ps_update "$TMP" "$PID" \
    '.stages = [
       {"id":"s1","stage":"brainstorm","status":"completed"},
       {"id":"s2","stage":"write_plan","status":"idle"}
     ]'
  CLAUDE_CODE_SESSION_ID="sess-resumer" "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r '.stages[0].status')" = "completed" ]
  [ "$(echo "$state" | jq -r '.stages[0].interrupted // false')" = "false" ]
  [ "$(echo "$state" | jq -r '.stages[1].status')" = "idle" ]
  [ "$(echo "$state" | jq -r '.stages[1].interrupted // false')" = "false" ]
}

@test "restart-stage.sh sets currentStage and clears lastVerdict" {
  ps_update "$TMP" "$PID" '.currentStage = "review_plan" | .lastVerdict = "has_issues"'
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "write_plan"
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "write_plan" ]
  [ "$(jq -r .lastVerdict ".atelier/pipelines/$PID/pipeline-state.json")" = "null" ]
}

@test "restart-stage.sh appends note to progress.md iteration log" {
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "implement"
  grep -q "Restart" ".atelier/pipelines/$PID/progress.md"
}

@test "restart-stage.sh --reset-attempts zeroes fixAttempts for the stage" {
  ps_update "$TMP" "$PID" '.fixAttempts = {"implement": 4, "review_spec": 2}'
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "implement" --reset-attempts
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r '.fixAttempts.implement')" = "0" ]
  [ "$(echo "$state" | jq -r '.fixAttempts.review_spec')" = "2" ]
}

@test "restart-stage.sh without flag preserves fixAttempts" {
  ps_update "$TMP" "$PID" '.fixAttempts = {"implement": 4}'
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "implement"
  [ "$(jq -r '.fixAttempts.implement' ".atelier/pipelines/$PID/pipeline-state.json")" = "4" ]
}

@test "restart-stage.sh marks trailing running stage skipped (unblocks Stop hook)" {
  ps_update "$TMP" "$PID" \
    '.stages = [{"id":"s1","stage":"review_spec","status":"running"}]
     | .currentStage = "review_spec" | .lastVerdict = null'
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "write_plan"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "skipped" ]
  [ "$(echo "$state" | jq -r '.stages[-1].interrupted')" = "true" ]
  [ "$(echo "$state" | jq -r .currentStage)" = "write_plan" ]
}

@test "restart-stage.sh leaves completed trailing stage untouched" {
  ps_update "$TMP" "$PID" \
    '.stages = [{"id":"s1","stage":"brainstorm","status":"completed"}]'
  "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "write_plan"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "completed" ]
  [ "$(echo "$state" | jq -r '.stages[-1].interrupted // false')" = "false" ]
}

@test "abort.sh sets status idle and writes error reason" {
  "$ATELIER_CC_ROOT/scripts/abort.sh" "$PID"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
  [ "$(jq -r .error ".atelier/pipelines/$PID/pipeline-state.json")" = "aborted by user" ]
}
