#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export ATELIER_CC_WORKSPACE="$TMP"
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
}
teardown() { rm -rf "$TMP"; }

drive_one_for_session() {
  local wsp="$1" pid="$2" sid="$3"
  local sp="$wsp/.atelier/pipelines/$pid/pipeline-state.json"
  local d
  d="$(printf '{"cwd":"%s","session_id":"%s"}' "$wsp" "$sid" \
      | "$ATELIER_CC_ROOT/hooks/stop.sh" || true)"
  [ -z "$d" ] && return 0
  local stage assigned mode
  stage="$(jq -r .currentStage "$sp")"
  assigned="$(jq -r '.stages[-1].assignedOutputPath // empty' "$sp")"
  mode="$(jq -r '.expectedMode' "$sp")"
  [ -n "$assigned" ] && { mkdir -p "$(dirname "$assigned")"; echo "stub $stage" > "$assigned"; }
  ps_complete_stage "$wsp" "$pid" "done" "$assigned"
  if [ "$mode" = "autonomous" ]; then
    printf '{"agent_type":"atelier:atelier-stage-worker","agent_id":"sim","cwd":"%s","session_id":"%s"}' \
      "$wsp" "$sid" | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh"
  fi
}

@test "two parallel sessions on one workspace each complete their pipeline" {
  PID_A="$(CLAUDE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'A')"
  PID_B="$(CLAUDE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'B')"
  ps_update "$TMP" "$PID_A" '.type = "plan" | .worktreeChoice = "in-tree"'
  ps_update "$TMP" "$PID_B" '.type = "plan" | .worktreeChoice = "in-tree"'
  for _ in $(seq 1 8); do
    drive_one_for_session "$TMP" "$PID_A" sess-A
    drive_one_for_session "$TMP" "$PID_B" sess-B
    sa="$(jq -r .status ".atelier/pipelines/$PID_A/pipeline-state.json")"
    sb="$(jq -r .status ".atelier/pipelines/$PID_B/pipeline-state.json")"
    [ "$sa" = "completed" ] && [ "$sb" = "completed" ] && break
  done
  [ "$(jq -r .status ".atelier/pipelines/$PID_A/pipeline-state.json")" = "completed" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID_B/pipeline-state.json")" = "completed" ]
}

@test "concurrent ps_update bursts across two sessions: no lost writes" {
  PID="$(CLAUDE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'shared')"
  ps_update "$TMP" "$PID" '.stepCounter = 0'
  for i in $(seq 1 30); do
    ( ps_update "$TMP" "$PID" '.stepCounter = ((.stepCounter // 0) + 1)' ) &
  done
  wait
  [ "$(jq -r .stepCounter ".atelier/pipelines/$PID/pipeline-state.json")" = "30" ]
}
