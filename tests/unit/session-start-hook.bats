#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'crashed task')"
  ps_update "$TMP" "$PID" '.currentStage = "implement" |
    .stages = [{id:"i1",stage:"implement",status:"running",startedAt:0}]'
  rm -f .atelier/active-pipeline
}
teardown() { rm -rf "$TMP"; }

drive() { printf '%s' "$1" | "$ATELIER_CC_ROOT/hooks/session-start.sh"; }

@test "running pipeline with stale heartbeat transitions to idle" {
  stale=$(( $(epoch_ms) - 300000 ))
  ps_update "$TMP" "$PID" ".lastHeartbeatMs = $stale"
  drive "{\"cwd\":\"$TMP\"}" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
  [ "$(jq -r '.stages[0].status' ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
}

@test "idle pipeline surfaces additionalContext" {
  ps_update "$TMP" "$PID" '.status = "idle"'
  out="$(drive "{\"cwd\":\"$TMP\"}")"
  [ "$(echo "$out" | jq -r .hookSpecificOutput.hookEventName)" = "SessionStart" ]
  [[ "$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)" == *"crashed task"* ]]
  [[ "$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)" == *"implement"* ]]
  [[ "$(echo "$out" | jq -r .hookSpecificOutput.additionalContext)" == *"/atelier resume"* ]]
}

@test "no pipelines: silent" {
  ps_set_status "$TMP" "$PID" "completed"
  out="$(drive "{\"cwd\":\"$TMP\"}")"
  [ -z "$out" ]
}

@test "stuck pipeline stays stuck (routing diagnostics not auto-cleared)" {
  # Routing marks pipelines stuck for diagnostic reasons (fix attempt cap,
  # missing artifact, unknown verdict). SessionStart must NOT silently demote
  # them to idle on the next session — that would erase the diagnostic.
  ps_update "$TMP" "$PID" '.status = "stuck" | .error = "fix attempt cap exceeded for review_spec" |
    .stages = [{id:"i1",stage:"implement",status:"stuck",startedAt:0}]'
  drive "{\"cwd\":\"$TMP\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [ "$(echo "$state" | jq -r '.stages[0].status')" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"fix attempt cap"* ]]
}

@test "one malformed pipeline-state.json doesn't poison the batch" {
  mkdir -p .atelier/pipelines/broken-pid
  echo "{ this is not valid" > .atelier/pipelines/broken-pid/pipeline-state.json
  stale=$(( $(epoch_ms) - 300000 ))
  ps_update "$TMP" "$PID" ".status = \"running\" | .lastHeartbeatMs = $stale"
  drive "{\"cwd\":\"$TMP\"}" >/dev/null
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
}
