#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
}
teardown() { rm -rf "$TMP"; }

@test "start-pipeline stamps sourceSessionId from CLAUDE_CODE_SESSION_ID" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  [ "$(jq -r .sourceSessionId ".atelier/pipelines/$PID/pipeline-state.json")" = "sess-A" ]
}

@test "start-pipeline fails when CLAUDE_CODE_SESSION_ID is unset" {
  run env -u CLAUDE_CODE_SESSION_ID "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a'
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_CODE_SESSION_ID"* ]]
}

@test ".atelier/active-pipeline is never written" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  [ ! -f .atelier/active-pipeline ]
  "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID" >/dev/null 2>&1 || true
  [ ! -f .atelier/active-pipeline ]
}

@test "find_owned_pipeline returns the session's running pipeline" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID_A="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  CLAUDE_CODE_SESSION_ID="sess-B" PID_B="$(CLAUDE_CODE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'b')"
  [ "$(find_owned_pipeline "$TMP" sess-A)" = "$PID_A" ]
  [ "$(find_owned_pipeline "$TMP" sess-B)" = "$PID_B" ]
  [ -z "$(find_owned_pipeline "$TMP" sess-ghost)" ]
}

@test "find_owned_pipeline fallback adopts an UNOWNED single running pipeline (from-specs / new window)" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  # Simulate the legitimate fallback case: state was reset / migrated and
  # sourceSessionId is empty. ANY session may adopt the single running one.
  ps_update "$TMP" "$PID" '.status = "running" | .sourceSessionId = null'
  [ "$(find_owned_pipeline "$TMP" sess-DIFFERENT)" = "$PID" ]
}

@test "find_owned_pipeline fallback REFUSES a pipeline owned by another live session (cross-session firewall)" {
  # Regression: with two parallel CC sessions each driving a pipeline in the
  # same workspace, when this session's pipeline ends (status != running), the
  # primary loop finds 0. The old "single running" fallback then stole the
  # OTHER session's pipeline and dispatched its next stage from this main agent.
  # Fix: never adopt when sourceSessionId is set to a non-matching value.
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID_A="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_set_status "$TMP" "$PID_A" "completed"            # A's pipeline finished
  PID_B="$(CLAUDE_CODE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'b')"
  # B's pipeline is the only running one in the workspace — A must NOT adopt it.
  [ -z "$(find_owned_pipeline "$TMP" sess-A)" ]
}

@test "find_owned_pipeline fallback is ambiguous-safe: >1 unowned running → empty" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID_A="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  PID_B="$(CLAUDE_CODE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'b')"
  ps_update "$TMP" "$PID_A" '.status = "running" | .sourceSessionId = null'
  ps_update "$TMP" "$PID_B" '.status = "running" | .sourceSessionId = null'
  [ -z "$(find_owned_pipeline "$TMP" sess-NEITHER)" ]
}

@test "find_owned_pipeline fallback ignores non-running pipelines" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_set_status "$TMP" "$PID" "idle"
  [ -z "$(find_owned_pipeline "$TMP" sess-DIFFERENT)" ]
}

@test "find_owned_pipeline ignores completed/idle/stuck pipelines" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_set_status "$TMP" "$PID" "completed"
  [ -z "$(find_owned_pipeline "$TMP" sess-A)" ]
  ps_set_status "$TMP" "$PID" "idle"
  [ -z "$(find_owned_pipeline "$TMP" sess-A)" ]
  ps_set_status "$TMP" "$PID" "stuck" "test"
  [ -z "$(find_owned_pipeline "$TMP" sess-A)" ]
}

@test "find_owned_pipeline picks most-recent on duplicate ownership (warns)" {
  export CLAUDE_CODE_SESSION_ID="sess-A"
  PID_OLD="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'old')"
  sleep 0.05
  PID_NEW="$("$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'new')"
  # `find_owned_pipeline` prints its result to stdout and emits a warn line to
  # stderr; check stdout in isolation rather than $output (which bats merges).
  result="$(find_owned_pipeline "$TMP" sess-A 2>/dev/null)"
  [ "$result" = "$PID_NEW" ]
  # The warn must appear when called with duplicate ownership.
  stderr="$(find_owned_pipeline "$TMP" sess-A 2>&1 >/dev/null)"
  [[ "$stderr" == *"2 running pipelines"* ]]
}

@test "resume.sh transfers ownership to the resuming session" {
  CLAUDE_CODE_SESSION_ID="sess-A" PID="$(CLAUDE_CODE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_update "$TMP" "$PID" '.status = "idle"'
  CLAUDE_CODE_SESSION_ID="sess-B" "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  [ "$(jq -r .sourceSessionId ".atelier/pipelines/$PID/pipeline-state.json")" = "sess-B" ]
}

@test "restart-stage.sh transfers ownership to the restarting session" {
  PID="$(CLAUDE_CODE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_update "$TMP" "$PID" '.type = "feature"'
  CLAUDE_CODE_SESSION_ID="sess-B" "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "brainstorm"
  [ "$(jq -r .sourceSessionId ".atelier/pipelines/$PID/pipeline-state.json")" = "sess-B" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

@test "restart-stage.sh fails when CLAUDE_CODE_SESSION_ID is unset" {
  PID="$(CLAUDE_CODE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  ps_update "$TMP" "$PID" '.type = "feature"'
  run env -u CLAUDE_CODE_SESSION_ID "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "brainstorm"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CLAUDE_CODE_SESSION_ID"* ]]
}
