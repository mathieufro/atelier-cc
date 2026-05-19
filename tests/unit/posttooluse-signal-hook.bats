#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  mkdir -p .atelier/topologies
  cat > .atelier/topologies/feature.json <<EOF2
{"name":"feature","description":"feature pipeline","stages":[
  {"name":"brainstorm","mode":"interactive","skill":"brainstorming-feature","requiresArtifact":true},
  {"name":"review_spec","mode":"autonomous","skill":"reviewing-specs","reviewBehavior":"fixing-specs","requiresArtifact":true},
  {"name":"implement","mode":"autonomous","skill":"implementing-plans","supportsPartial":true}
]}
EOF2
  for s in brainstorming-feature reviewing-specs implementing-plans fixing-specs; do
    backup_skill "$s"
    cat > "$ATELIER_CC_ROOT/skills/$s/SKILL.md" <<EOF2
---
name: $s
---
Body of $s
EOF2
  done
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'build oauth')"
  ps_update "$TMP" "$PID" '.type = "feature"'
}
teardown() {
  rm -rf "$TMP"
  for s in brainstorming-feature reviewing-specs implementing-plans fixing-specs; do
    restore_skill "$s"
  done
}

# Compact JSON PostToolUse payload. ok=1 → success tool_response, ok=0 → error.
payload() {
  local ok="$1"
  local text
  if [ "$ok" = "1" ]; then
    text="Stage signal received. STOP YOUR TURN IMMEDIATELY — no further output or tool calls."
    jq -nc --arg cwd "$TMP" --arg t "$text" \
      '{cwd:$cwd, session_id:"sess-t", tool_name:"mcp__atelier__atelier_signal",
        tool_response:{content:[{type:"text",text:$t}]}}'
  else
    jq -nc --arg cwd "$TMP" \
      '{cwd:$cwd, session_id:"sess-t", tool_name:"mcp__atelier__atelier_signal",
        tool_response:{content:[{type:"text",text:"pipeline not found: x"}], isError:true}}'
  fi
}

drive_post() { printf '%s' "$1" | "$ATELIER_CC_ROOT/hooks/posttooluse-signal.sh"; }

@test "interactive stage signal: dispatches next stage deterministically (the hang fix)" {
  # quick_plan-style case: an interactive stage completed in the MAIN agent.
  # Stop may never fire (model keeps rambling); PostToolUse must advance now.
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .expectedMode = "interactive" |
    .lastVerdict = "done" |
    .stages = [{id:"b1",stage:"brainstorm",status:"completed",verdict:"done"}]'
  result="$(drive_post "$(payload 1)")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:atelier-stage-worker"* ]]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "review_spec" ]
}


@test "signal from INSIDE a subagent (agent_id present): hard no-op even for interactive expectedMode" {
  # Regression: PostToolUse fires for subagent-internal tool calls too, with
  # the parent session_id. Brainstorm-family interactive stages run via a
  # stage-worker subagent (expectedMode stays "interactive"). If this hook
  # acted, it would inject "Call the Agent tool ..." INTO the subagent and
  # wedge the pipeline. agent_id present => subagent => must do nothing.
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .expectedMode = "interactive" |
    .lastVerdict = "done" |
    .stages = [{id:"b1",stage:"brainstorm",status:"completed",verdict:"done"}]'
  sub_payload="$(jq -nc --arg cwd "$TMP" \
    '{cwd:$cwd, session_id:"sess-t", agent_id:"sub-abc123", agent_type:"atelier:atelier-stage-worker",
      tool_name:"mcp__atelier__atelier_signal",
      tool_response:{content:[{type:"text",text:"Stage signal received. End your turn NOW."}]}}')"
  result="$(drive_post "$sub_payload")"
  [ -z "$result" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "brainstorm" ]
  [ "$(jq -r '.stages | length' ".atelier/pipelines/$PID/pipeline-state.json")" = "1" ]
}

@test "autonomous stage signal: no-op (SubagentStop owns that boundary; avoids double-dispatch)" {
  ps_update "$TMP" "$PID" '.currentStage = "implement" | .expectedMode = "autonomous" |
    .lastVerdict = "done" |
    .stages = [{id:"i1",stage:"implement",status:"completed",verdict:"done"}]'
  result="$(drive_post "$(payload 1)")"
  [ -z "$result" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "implement" ]
  [ "$(jq -r '.stages | length' ".atelier/pipelines/$PID/pipeline-state.json")" = "1" ]
}

@test "pre-classify gate (empty expectedMode): dispatches topology first stage" {
  # classify carries no verdict and leaves expectedMode unset; the first
  # main-agent signal must still deterministically launch stage 1.
  ps_update "$TMP" "$PID" '.currentStage = null | .expectedMode = null | .lastVerdict = null'
  result="$(drive_post "$(payload 1)")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"Body of brainstorming-feature"* ]]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "brainstorm" ]
}

@test "errored signal response: no-op (state un-advanced, must not mis-route)" {
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .expectedMode = "interactive" |
    .lastVerdict = "done" |
    .stages = [{id:"b1",stage:"brainstorm",status:"completed",verdict:"done"}]'
  result="$(drive_post "$(payload 0)")"
  [ -z "$result" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "brainstorm" ]
}

@test "no resolvable running pipeline (not running, no fallback): silent no-op" {
  # Ownership now falls back to "the single running pipeline in the workspace",
  # so the no-op case is "nothing running to adopt" (idle/terminal), not merely
  # a sourceSessionId mismatch. The subagent (agent_id) no-op is covered above.
  ps_update "$TMP" "$PID" '.status = "idle" | .currentStage = "brainstorm" | .expectedMode = "interactive" | .lastVerdict = "done"'
  foreign="$(jq -nc --arg cwd "$TMP" \
    '{cwd:$cwd, session_id:"sess-Other", tool_name:"mcp__atelier__atelier_signal",
      tool_response:{content:[{type:"text",text:"Stage signal received."}]}}')"
  result="$(drive_post "$foreign")"
  [ -z "$result" ]
}

@test "non-owner main-agent signal, single running pipeline: fallback adopts and advances (deterministic ownership)" {
  ps_update "$TMP" "$PID" '.status = "running" | .currentStage = "brainstorm" | .expectedMode = "interactive" | .lastVerdict = "done" | .stages = [{id:"b1",stage:"brainstorm",status:"completed",verdict:"done"}]'
  foreign="$(jq -nc --arg cwd "$TMP" \
    '{cwd:$cwd, session_id:"sess-Other", tool_name:"mcp__atelier__atelier_signal",
      tool_response:{content:[{type:"text",text:"Stage signal received."}]}}')"
  result="$(drive_post "$foreign")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
}

@test "terminal pipeline status (completed): no-op" {
  ps_update "$TMP" "$PID" '.status = "completed" | .currentStage = "implement" | .expectedMode = "interactive"'
  result="$(drive_post "$(payload 1)")"
  [ -z "$result" ]
}

@test "interactive->interactive boundary embeds skill body + pipelineId" {
  ps_update "$TMP" "$PID" '.currentStage = null | .expectedMode = null | .lastVerdict = null'
  result="$(drive_post "$(payload 1)")"
  reason="$(echo "$result" | jq -r .reason)"
  [[ "$reason" == *"Body of brainstorming-feature"* ]]
  [[ "$reason" == *"pipelineId"* ]]
  [[ "$reason" == *"$PID"* ]]
}
