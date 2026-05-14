#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir -p .git .atelier/topologies
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  # Test fixture topology — declare the first stage as a variable so assertions
  # don't rely on a hardcoded literal that drifts if this fixture is renamed.
  FIRST_STAGE="brainstorm"
  cat > .atelier/topologies/feature.json <<EOF
{"name":"feature","stages":[
  {"name":"$FIRST_STAGE","mode":"interactive","skill":"brainstorming","requiresArtifact":true}
]}
EOF
  PID_A="$(CLAUDE_CODE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'a')"
  PID_B="$(CLAUDE_CODE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'b')"
  ps_update "$TMP" "$PID_A" '.type = "feature"'
  ps_update "$TMP" "$PID_B" '.type = "feature"'
}
teardown() { rm -rf "$TMP"; }

@test "Stop hook routes only the pipeline owned by its session_id" {
  printf '{"cwd":"%s","session_id":"sess-A"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID_A/pipeline-state.json")" = "$FIRST_STAGE" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID_B/pipeline-state.json")" = "null" ]
}

@test "Stop hook with no owned pipeline is a silent no-op" {
  printf '{"cwd":"%s","session_id":"sess-Other"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID_A/pipeline-state.json")" = "null" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID_B/pipeline-state.json")" = "null" ]
}

@test "SubagentStop only mutates its session's owned pipeline" {
  ps_update "$TMP" "$PID_A" '.currentStage = "implement" | .expectedSubagent = "atelier:atelier-stage-worker" |
    .expectedMode = "autonomous" |
    .stages = [{id:"i1",stage:"implement",status:"running",startedAt:0}]'
  ps_update "$TMP" "$PID_B" '.currentStage = "implement" | .expectedSubagent = "atelier:atelier-stage-worker" |
    .expectedMode = "autonomous" |
    .stages = [{id:"i2",stage:"implement",status:"running",startedAt:0}]'
  printf '{"cwd":"%s","session_id":"sess-A","agent_type":"atelier:atelier-stage-worker","agent_id":"a"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh"
  [ "$(jq -r .status ".atelier/pipelines/$PID_A/pipeline-state.json")" = "stuck" ]
  [ "$(jq -r .status ".atelier/pipelines/$PID_B/pipeline-state.json")" = "running" ]
}

@test "SessionStart's idle summary lists only this session's idle pipelines" {
  ps_update "$TMP" "$PID_A" '.status = "idle"'
  ps_update "$TMP" "$PID_B" '.status = "idle"'
  out="$(printf '{"cwd":"%s","session_id":"sess-A"}' "$TMP" \
    | "$ATELIER_CC_ROOT/hooks/session-start.sh")"
  ctx="$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')"
  [[ "$ctx" == *"$PID_A"* ]]
  [[ "$ctx" != *"$PID_B"* ]]
}
