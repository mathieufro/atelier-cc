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
  {"name":"implement","mode":"autonomous","skill":"implementing-plans","supportsPartial":true},
  {"name":"validate","mode":"autonomous","skill":"validating"}
]}
EOF2
  for s in brainstorming-feature reviewing-specs implementing-plans validating fixing-specs; do
    backup_skill "$s"
    cat > "$ATELIER_CC_ROOT/skills/$s/SKILL.md" <<EOF2
---
name: $s
---
Body of $s
EOF2
  done
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'build oauth')"
  # start-pipeline leaves type=null pre-classify; these tests are routing-only,
  # so simulate a completed classify by setting type explicitly.
  ps_update "$TMP" "$PID" '.type = "feature"'
}
teardown() {
  rm -rf "$TMP"
  for s in brainstorming-feature reviewing-specs implementing-plans validating fixing-specs; do
    restore_skill "$s"
  done
}

drive_stop() {
  printf '%s' "$1" | "$ATELIER_CC_ROOT/hooks/stop.sh"
}

@test "stop_hook_active=true does NOT short-circuit (routing-via-Stop needs subsequent fires)" {
  # Real Claude Code sets stop_hook_active=true on every re-entry after a
  # blocking Stop hook — including the legitimate re-entry after an Agent tool
  # call returns. Hard-coding "exit on stop_hook_active" stranded the pipeline
  # after the first autonomous stage signaled done. The hook now routes by
  # state: a completed-with-verdict stage advances even when the flag is set.
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .lastVerdict = "done" |
    .stages = [{id:"b1",stage:"brainstorm",status:"completed",verdict:"done"}]'
  result="$(drive_stop "{\"stop_hook_active\":true,\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
}

@test "stage-in-progress with compiledPromptPath (subagent actually launched): Stop hook exits silently" {
  # When PreToolUse fired (compiledPromptPath set), a subagent is running. Stop
  # must NOT advance — we're mid-stage.
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .lastVerdict = null |
    .stages = [{id:"b1",stage:"brainstorm",status:"running",compiledPromptPath:"/tmp/x.md"}]'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$result" ]
}

@test "stage-in-progress with sessionId (subagent stopped at least once): Stop hook exits silently" {
  ps_update "$TMP" "$PID" '.currentStage = "implement" | .lastVerdict = null | .expectedMode = "autonomous" |
    .stages = [{id:"i1",stage:"implement",status:"running",sessionId:"sub-1"}]'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$result" ]
}

@test "ghost stage (running + no compiledPromptPath + no sessionId): Stop hook re-emits dispatch (regression: pipeline silently wedged when main agent ignored SubagentStop block reason)" {
  # SubagentStop dispatched the next stage (appended running row, emitted block
  # reason). Main agent saw the just-completed subagent's terminal text saying
  # "I cannot call the Agent tool here — my stage_complete signal has already
  # been emitted" and stopped without calling Agent. PreToolUse never fired, so
  # compiledPromptPath stays null. Without recovery the pipeline silently
  # wedges here. Stop must re-emit the dispatch directive for the existing row.
  ps_update "$TMP" "$PID" '.currentStage = "implement" | .lastVerdict = null |
    .expectedMode = "autonomous" | .expectedSubagent = "atelier:atelier-stage-worker" | .expectedSkill = "implementing-plans" |
    .stages = [{id:"i1",stage:"implement",status:"running",sessionId:null,compiledPromptPath:null,assignedOutputPath:null}]'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:atelier-stage-worker"* ]]
  [[ "$(echo "$result" | jq -r .reason)" == *"<MARKER:next-stage>"* ]]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:implement"* ]]
  # Must NOT have appended a new stage row.
  [ "$(jq -r '.stages | length' ".atelier/pipelines/$PID/pipeline-state.json")" = "1" ]
}

@test "no owned pipeline: exits with no decision" {
  # Foreign session_id resolves to no owned pipeline → silent no-op.
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-Other\"}")"
  [ -z "$result" ]
}

@test "awaiting classify (type=null): exits with no decision, does not dispatch" {
  # Reproduce the pre-classify state that start-pipeline now writes: type=null,
  # currentStage=null, active-pipeline pointer set. Stop hook must NOT route.
  ps_update "$TMP" "$PID" '.type = null'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$result" ]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "null" ]
}

@test "first dispatch: routes to topology's first stage (interactive)" {
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"Body of brainstorming-feature"* ]]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "brainstorm" ]
}

@test "interactive dispatch reason: conversational, end-turn-to-yield, no delegation, no AskUserQuestion" {
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  reason="$(echo "$result" | jq -r .reason)"
  [[ "$reason" == *"Run this stage YOURSELF"* ]]
  [[ "$reason" == *"back-and-forth chat"* ]]
  [[ "$reason" == *"end your turn"* ]]
  [[ "$reason" == *"do NOT call the Agent tool"* ]]
  [[ "$reason" == *"SendMessage"* ]]
  # Must steer AWAY from AskUserQuestion (conversational is the design).
  [[ "$reason" == *"Do NOT use AskUserQuestion"* ]]
  # Still carries the methodology + signaling contract.
  [[ "$reason" == *"Body of brainstorming-feature"* ]]
  [[ "$reason" == *"atelier_signal"* ]]
}

@test "interactive stage mid-conversation: Stop is a SILENT no-op (turn-end yields to user, never blocks)" {
  # The core fix: while an interactive stage is running and unsignaled, the
  # agent ending its turn IS it asking the user something and yielding. Stop
  # must not re-emit/block — a block would stop the user ever answering.
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .expectedMode = "interactive" |
    .lastVerdict = null |
    .stages = [{id:"b1",stage:"brainstorm",status:"running",compiledPromptPath:null,sessionId:null}]'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ -z "$result" ]
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "running" ]
  [ "$(echo "$state" | jq -r '.stages[-1].status')" = "running" ]
  [ "$(echo "$state" | jq -r '.stages | length')" = "1" ]
}

@test "verdict=done advances to next stage (autonomous)" {
  ps_update "$TMP" "$PID" '.currentStage = "brainstorm" | .lastVerdict = "done" |
    .stages = [{id:"b1",stage:"brainstorm",status:"completed"}]'
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  [ "$(echo "$result" | jq -r .decision)" = "block" ]
  [[ "$(echo "$result" | jq -r .reason)" == *"atelier:atelier-stage-worker"* ]]
  [[ "$(echo "$result" | jq -r .reason)" == *"<MARKER:next-stage>"* ]]
  [ "$(jq -r .currentStage ".atelier/pipelines/$PID/pipeline-state.json")" = "review_spec" ]
  [ "$(jq -r .expectedSubagent ".atelier/pipelines/$PID/pipeline-state.json")" = "atelier:atelier-stage-worker" ]
}

@test "has_issues on review stage increments fixAttempts and dispatches fix" {
  ps_update "$TMP" "$PID" '.currentStage = "review_spec" | .lastVerdict = "has_issues" |
    .stages = [{id:"rs1",stage:"review_spec",status:"completed"}]'
  drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .currentStage)" = "fix_spec" ]
  [ "$(echo "$state" | jq -r '.fixAttempts.review_spec')" = "1" ]
  [ "$(echo "$state" | jq -r '.stages[-1].dynamicallyInserted')" = "true" ]
  [ "$(echo "$state" | jq -r '.stages[-1].parentReviewStageId')" = "rs1" ]
}

@test "fix attempt cap exceeded -> status idle, error set" {
  ps_update "$TMP" "$PID" \
    '.currentStage = "review_spec" | .lastVerdict = "has_issues" |
     .fixAttempts = {"review_spec":5} |
     .stages = [{id:"rs1",stage:"review_spec",status:"completed"}]'
  drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "idle" ]
  [[ "$(echo "$state" | jq -r .error)" == *"fix attempt cap"* ]]
}

@test "end of topology -> status completed" {
  ps_update "$TMP" "$PID" '.currentStage = "validate" | .lastVerdict = "done" |
    .stages = [{id:"v1",stage:"validate",status:"completed"}]'
  drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "completed" ]
  [ "$(echo "$state" | jq -r '.completedAt | type')" = "number" ]
}

@test "missing topology -> status stuck" {
  ps_update "$TMP" "$PID" '.type = "nonexistent"'
  drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"topology"* ]]
}

@test "corrupt topology JSON -> status stuck" {
  cat > .atelier/topologies/feature.json <<EOF2
{ this is not valid json
EOF2
  drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}" >/dev/null
  state="$(cat ".atelier/pipelines/$PID/pipeline-state.json")"
  [ "$(echo "$state" | jq -r .status)" = "stuck" ]
  [[ "$(echo "$state" | jq -r .error)" == *"topology"* ]]
}

@test "owned pipeline state file missing: silent no-op" {
  rm -rf ".atelier/pipelines/$PID"
  run drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "Stop hook interactive reason embeds pipelineId" {
  result="$(drive_stop "{\"cwd\":\"$TMP\",\"session_id\":\"sess-t\"}")"
  reason="$(echo "$result" | jq -r .reason)"
  [[ "$reason" == *"pipelineId"* ]]
  [[ "$reason" == *"$PID"* ]]
}
