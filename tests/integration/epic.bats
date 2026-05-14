#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_SESSION_ID="sess-t"
  export ATELIER_CC_WORKSPACE="$TMP"
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
}
teardown() { rm -rf "$TMP"; }

@test "epic pipeline reaches completed" {
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'epic initiative')"
  ps_update "$TMP" "$PID" '.type = "epic" | .worktreeChoice = "in-tree"'

  for i in $(seq 1 12); do
    status="$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")"
    [ "$status" = "completed" ] && break
    [ "$status" = "stuck" ] && { echo "stuck: $(jq -r .error ".atelier/pipelines/$PID/pipeline-state.json")" >&2; return 1; }
    drive_one_iteration "$TMP" "$PID"
  done
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "completed" ]
}
