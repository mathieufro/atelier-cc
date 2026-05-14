#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_SESSION_ID="sess-self"
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'x')"
}
teardown() { rm -rf "$TMP"; }

@test "ps_init seeds lastHeartbeatMs" {
  hb="$(jq -r .lastHeartbeatMs ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$hb" != "null" ] && [ "$hb" -gt 0 ]
}

@test "ps_update bumps lastHeartbeatMs monotonically" {
  before="$(jq -r .lastHeartbeatMs ".atelier/pipelines/$PID/pipeline-state.json")"
  sleep 0.05
  ps_update "$TMP" "$PID" '.title = "x"'
  after="$(jq -r .lastHeartbeatMs ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$after" -gt "$before" ]
}

@test "SessionStart preserves running+fresh+foreign pipelines" {
  ps_update "$TMP" "$PID" \
    '.status = "running" | .sourceSessionId = "sess-foreign" | .lastHeartbeatMs = $hb' \
    --argjson hb "$(epoch_ms)"
  printf '{"cwd":"%s","session_id":"sess-self"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/session-start.sh" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

@test "SessionStart demotes running+stale pipelines to idle (regardless of owner)" {
  stale="$(( $(epoch_ms) - 300000 ))"  # 5min ago
  ps_update "$TMP" "$PID" \
    '.status = "running" | .sourceSessionId = "sess-foreign" | .lastHeartbeatMs = $hb' \
    --argjson hb "$stale"
  printf '{"cwd":"%s","session_id":"sess-self"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/session-start.sh" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
}

@test "SessionStart never auto-demotes stuck pipelines (heartbeat irrelevant)" {
  stale="$(( $(epoch_ms) - 300000 ))"
  ps_update "$TMP" "$PID" \
    '.status = "stuck" | .error = "fix cap" | .lastHeartbeatMs = $hb' \
    --argjson hb "$stale"
  printf '{"cwd":"%s","session_id":"sess-self"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/session-start.sh" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "stuck" ]
}

@test "pipeline with no lastHeartbeatMs falls back to createdAt (no false demotion)" {
  ps_update "$TMP" "$PID" \
    '.status = "running" | .lastHeartbeatMs = null | .createdAt = $cr' \
    --argjson cr "$(epoch_ms)"
  printf '{"cwd":"%s","session_id":"sess-self"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/session-start.sh" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}
