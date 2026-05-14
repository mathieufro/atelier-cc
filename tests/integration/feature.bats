#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_CODE_SESSION_ID="sess-t"
  export ATELIER_CC_WORKSPACE="$TMP"
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
}
teardown() { rm -rf "$TMP"; }

@test "feature pipeline reaches completed for clean run" {
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'feature x')"
  ps_update "$TMP" "$PID" '.type = "feature" | .worktreeChoice = "in-tree"'
  for i in $(seq 1 30); do
    status="$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")"
    [ "$status" = "completed" ] && break
    [ "$status" = "stuck" ] && { echo "stuck: $(jq -r .error ".atelier/pipelines/$PID/pipeline-state.json")" >&2; return 1; }
    drive_one_iteration "$TMP" "$PID"
  done
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "completed" ]
}

@test "feature pipeline inserts fix_spec on has_issues from review_spec" {
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'feature y')"
  ps_update "$TMP" "$PID" '.type = "feature" | .worktreeChoice = "in-tree"'

  for i in $(seq 1 10); do
    drive_one_iteration "$TMP" "$PID"
    cur="$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")"
    [ "$cur" = "review_spec" ] && break
  done
  cur="$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$cur" = "review_spec" ]

  # Stage was already dispatched in the loop's last iteration and completed with done.
  # We need to back up: re-set state to mid-review_spec, then signal has_issues.
  ps_update "$TMP" "$PID" '.currentStage = "review_spec" | .lastVerdict = "has_issues"'
  printf '{"agent_type":"atelier:atelier-stage-worker","agent_id":"sim","cwd":"%s","session_id":"sess-t"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh" || true
  printf '{"cwd":"%s","session_id":"sess-t"}' "$TMP" | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null

  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .currentStage)" = "fix_spec" ]
  [ "$(echo "$state" | jq -r '.stages[-1].dynamicallyInserted')" = "true" ]
  [ "$(echo "$state" | jq -r '.fixAttempts.review_spec')" = "1" ]
}

@test "resume after mid-stage crash re-dispatches the same stage with RESUMING header" {
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'feature z')"
  ps_update "$TMP" "$PID" '.type = "feature" | .worktreeChoice = "in-tree"'

  for i in $(seq 1 15); do
    drive_one_iteration "$TMP" "$PID"
    cur="$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")"
    [ "$cur" = "implement" ] && break
  done
  cur="$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$cur" = "implement" ]

  # Simulate crash mid-implement: rewind so implement is running and the
  # heartbeat is stale (>120s), so SessionStart treats the pipeline as crashed.
  stale=$(( $(epoch_ms) - 300000 ))
  ps_update "$TMP" "$PID" ".lastVerdict = null | .lastHeartbeatMs = $stale |
    .stages |= (.[:-1] + [.[-1] + {status:\"running\", verdict:null, completedAt:null}])"

  # SessionStart marks running->idle.
  ss_out="$(printf '{"cwd":"%s","session_id":"sess-t"}' "$TMP" | "$ATELIER_CC_ROOT/hooks/session-start.sh")"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
  [ "$(jq -r '.stages[-1].status' ".atelier/pipelines/$PID/pipeline-state.json")" = "idle" ]
  ctx="$(echo "$ss_out" | jq -r .hookSpecificOutput.additionalContext)"
  [[ "$ctx" == *"feature z"* ]]
  [[ "$ctx" == *"implement"* ]]
  [[ "$ctx" == *"/atelier resume"* ]]

  # User resumes.
  "$ATELIER_CC_ROOT/scripts/resume.sh" "$PID"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]

  # Stop hook fires next: re-dispatch implement, NOT advance past it.
  before_stage_count="$(jq '.stages | length' ".atelier/pipelines/$PID/pipeline-state.json")"
  printf '{"cwd":"%s","session_id":"sess-t"}' "$TMP" | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "implement" ]
  after_stage_count="$(jq '.stages | length' ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$after_stage_count" -gt "$before_stage_count" ]
  [ "$(jq -r '.stages[-1].stage' ".atelier/pipelines/$PID/pipeline-state.json")" = "implement" ]

  # Compile-prompt must produce a RESUMING block.
  compiled="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "implement")"
  [[ "$compiled" == *"RESUMING"* ]]
  [[ "$compiled" == *"progress.md"* ]]
}
