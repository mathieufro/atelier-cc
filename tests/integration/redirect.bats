#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_SESSION_ID="sess-t"
  export ATELIER_CC_WORKSPACE="$TMP"
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
}
teardown() { rm -rf "$TMP"; }

@test "redirect Path B: re-dispatch with USER REDIRECT in compiled prompt" {
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'feature task')"
  ps_update "$TMP" "$PID" '.type = "feature" | .worktreeChoice = "in-tree"'
  for i in $(seq 1 15); do
    drive_one_iteration "$TMP" "$PID"
    [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "implement" ] && break
  done
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "implement" ]

  bash "$ATELIER_CC_ROOT/scripts/redirect.sh" 'use protocol X instead'
  bash "$ATELIER_CC_ROOT/scripts/restart-stage.sh" "$PID" "implement"

  printf '{"cwd":"%s","session_id":"sess-t"}' "$TMP" | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null
  compiled="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "implement")"
  [[ "$compiled" == *"USER REDIRECT"* ]]
  [[ "$compiled" == *"protocol X"* ]]
  [ "$(jq -r .pendingRedirect ".atelier/pipelines/$PID/pipeline-state.json")" = "null" ]
}
