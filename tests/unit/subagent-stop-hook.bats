#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  mkdir -p .atelier/topologies
  cat > .atelier/topologies/feature.json <<EOF2
{"name":"feature","stages":[{"name":"implement","mode":"autonomous","skill":"implementing-plans","requiresArtifact":true}]}
EOF2
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'x')"
  ps_update "$TMP" "$PID" \
    ".currentStage = \"implement\" | .expectedSubagent = \"atelier:atelier-stage-worker\" |
     .expectedMode = \"autonomous\" |
     .stages = [{id:\"i1\",stage:\"implement\",status:\"running\",startedAt:0,assignedOutputPath:\".atelier/pipelines/$PID/01-impl.md\"}]"
}
teardown() { rm -rf "$TMP"; }

drive() { printf '%s' "$1" | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh"; }

@test "non-atelier subagent when no expectedSubagent set: no-op" {
  ps_update "$TMP" "$PID" '.expectedSubagent = null | .expectedMode = null'
  drive "{\"agent_type\":\"general-purpose\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

@test "wrong subagent dispatched: pipeline stuck with diagnostic" {
  drive "{\"agent_type\":\"general-purpose\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"PreToolUse fallback"* ]]
  [[ "$(echo "$state" | jq -r .error)" == *"general-purpose"* ]]
  [[ "$(echo "$state" | jq -r '.stages[-1].error')" == *"PreToolUse fallback"* ]]
}

@test "no verdict signaled: stage and pipeline stuck" {
  ps_update "$TMP" "$PID" '.lastVerdict = null | .stages[-1].compiledPromptPath = "/tmp/compiled.md"'
  drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [[ "$(echo "$state" | jq -r '.stages[-1].error')" == *"without signaling"* ]]
}

@test "no verdict on ghost-dispatched stage re-emits dispatch instead of marking stuck" {
  ps_update "$TMP" "$PID" '.lastVerdict = null | .stages[-1].compiledPromptPath = null | .stages[-1].sessionId = null'
  result="$(drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:atelier-stage-worker"* ]]
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].error // empty')" = "" ]
}

@test "verdict present, artifact present: sessionId recorded, status running" {
  out_path=".atelier/pipelines/$PID/01-impl.md"
  echo "ok" > "$out_path"
  ps_update "$TMP" "$PID" ".lastVerdict = \"done\" | .lastOutputPath = \"$out_path\""
  drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].sessionId')" = "abc" ]
}

@test "required artifact missing: stage stuck with diagnostic" {
  ps_update "$TMP" "$PID" '.lastVerdict = "done" | .lastOutputPath = "/no/such/path.md"'
  drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"missing required artifact"* ]]
}

@test "no in-flight autonomous stage: SubagentStop is a no-op even for atelier-stage-worker" {
  ps_update "$TMP" "$PID" '.expectedSubagent = null | .expectedMode = null'
  drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"abc\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}

# ── Interactive stage run via a stage-worker subagent (brainstorm family). ───
# The robustness fix: when the FINAL stage worker of an interactive stage
# signals a verdict and ends, SubagentStop must advance the pipeline itself —
# NOT wait for the main agent to voluntarily end its turn (the wedge class).

@test "interactive stage, verdict set: SubagentStop advances WITHOUT waiting for main Stop" {
  cat > .atelier/topologies/tb.json <<EOF2
{"name":"tb","stages":[
  {"name":"task_brainstorm","mode":"interactive","skill":"task-brainstorming","requiresArtifact":true},
  {"name":"review_task","mode":"autonomous","skill":"reviewing-task-plans"}
]}
EOF2
  spec="$TMP/.atelier/pipelines/$PID/02-spec.md"; echo "spec body" > "$spec"
  ps_update "$TMP" "$PID" ".type = \"tb\" | .currentStage = \"task_brainstorm\" |
    .expectedSubagent = \"atelier:atelier-stage-worker\" | .expectedMode = \"interactive\" |
    .lastVerdict = \"done\" | .lastOutputPath = \"$spec\" |
    .stages = [{id:\"tb1\",stage:\"task_brainstorm\",status:\"completed\",verdict:\"done\",assignedOutputPath:\"$spec\",outputPath:\"$spec\"}]"
  result="$(drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"fin\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:atelier-stage-worker"* ]]
  [ "$(echo "$state" | jq -r .currentStage)" = "review_task" ]
  [ "$(echo "$state" | jq -r .status)" = "running" ]
}

@test "interactive stage, NO verdict: SubagentStop is a no-op (intermediate continuation, not stuck)" {
  # Main re-spawns stage workers to relay AskUserQuestion answers; those end
  # without signaling. Must NOT mark stuck or dispatch — the stage isn't done.
  ps_update "$TMP" "$PID" '.currentStage = "task_brainstorm" |
    .expectedSubagent = "atelier:atelier-stage-worker" | .expectedMode = "interactive" |
    .lastVerdict = null |
    .stages = [{id:"tb1",stage:"task_brainstorm",status:"running",compiledPromptPath:null,sessionId:null}]'
  result="$(drive "{\"agent_type\":\"atelier:atelier-stage-worker\",\"agent_id\":\"c1\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ -z "$result" ]
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].error // empty')" = "" ]
  [ "$(echo "$state" | jq -r '.stages | length')" = "1" ]
}

@test "interactive helper subagent of unexpected type, no verdict: no-op (not wrong-subagent stuck)" {
  ps_update "$TMP" "$PID" '.currentStage = "task_brainstorm" |
    .expectedSubagent = "atelier:atelier-stage-worker" | .expectedMode = "interactive" |
    .lastVerdict = null |
    .stages = [{id:"tb1",stage:"task_brainstorm",status:"running"}]'
  drive "{\"agent_type\":\"general-purpose\",\"agent_id\":\"h1\",\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  [ "$(jq -r .status ".atelier/pipelines/$PID/pipeline-state.json")" = "running" ]
}
