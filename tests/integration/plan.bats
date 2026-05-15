#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_CODE_SESSION_ID="sess-t"
  export ATELIER_CC_WORKSPACE="$TMP"
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
}
teardown() { rm -rf "$TMP"; }

@test "plan pipeline reaches completed with all artifacts present" {
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'add a comment')"
  ps_update "$TMP" "$PID" '.type = "plan" | .worktreeChoice = "in-tree"'

  for i in $(seq 1 20); do
    status="$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")"
    [ "$status" = "completed" ] && break
    if [ "$status" = "stuck" ]; then
      echo "pipeline stuck: $(jq -r .error ".atelier/pipelines/$PID/pipeline-state.json")" >&2
      return 1
    fi
    drive_one_iteration "$TMP" "$PID"
  done
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "completed" ]

  ls "$TMP/.atelier/pipelines/$PID"/*-plan.md
  ls "$TMP/.atelier/pipelines/$PID"/*-plan-review.md
}

@test "plan_gate execute dispatches implementation instead of completing" {
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'add a comment')"
  ps_update "$TMP" "$PID" '.type = "plan" | .worktreeChoice = "in-tree"'

  for i in $(seq 1 10); do
    [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "plan_gate" ] && break
    drive_one_iteration "$TMP" "$PID"
  done

  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "plan_gate" ]
  ps_complete_stage "$TMP" "$PID" "done" "" "implement"
  result="$(printf '{"cwd":"%s","session_id":"sess-t"}' "$TMP" | "$ATELIER_CC_ROOT/hooks/stop.sh")"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"

  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r .currentStage)" = "implement" ]
  [ "$(echo "$state" | jq -r '.stages[-1].dynamicallyInserted')" = "true" ]
  [ "$(echo "$state" | jq -r .expectedMode)" = "autonomous" ]
  [ "$(echo "$state" | jq -r '.lastAction // empty')" = "" ]
}
