#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  WSP="$(mktemp -d)"
  PID="2026-05-14-test-a1b2"
}

teardown() { rm -rf "$WSP"; }

@test "ps_path returns expected path" {
  result="$(ps_path "$WSP" "$PID")"
  [ "$result" = "$WSP/.atelier/pipelines/$PID/pipeline-state.json" ]
}

@test "ps_init writes Atelier PipelineStateData shape" {
  ps_init "$WSP" "$PID" "build oauth" "feature"
  local sp; sp="$(ps_path "$WSP" "$PID")"
  [ -f "$sp" ]
  [ "$(jq -r .id "$sp")" = "$PID" ]
  [ "$(jq -r .prompt "$sp")" = "build oauth" ]
  [ "$(jq -r .type "$sp")" = "feature" ]
  [ "$(jq -r .status "$sp")" = "running" ]
  [ "$(jq -r .workspacePath "$sp")" = "$WSP" ]
  [ "$(jq -r .pipelineDir "$sp")" = ".atelier/pipelines/$PID" ]
  [ "$(jq -r .currentStage "$sp")" = "null" ]
  [ "$(jq -r '.stages | length' "$sp")" = "0" ]
  [ "$(jq -r '.stepCounter' "$sp")" = "0" ]
  [ "$(jq -r '.stageModelsConfirmed' "$sp")" = "false" ]
  [ "$(jq -r '.createdAt | type' "$sp")" = "number" ]
}

@test "ps_init populates all Atelier-required fields with valid defaults" {
  ps_init "$WSP" "$PID" "x" "task"
  local sp; sp="$(ps_path "$WSP" "$PID")"
  for key in fromPipelineId fromStage model variant title completedAt gitBranch gitBaseBranch gitBaseCommit worktreePath worktreeChoice sourceSessionId; do
    val="$(jq -r ".$key" "$sp")"
    if [ "$val" != "null" ]; then
      echo "expected $key=null, got $val" >&2
      return 1
    fi
  done
  [ "$(jq -r '.stageModels | type' "$sp")" = "object" ]
  [ "$(jq -r '.error' "$sp")" = "null" ]
}

@test "ps_read returns nested values" {
  ps_init "$WSP" "$PID" "p" "plan"
  [ "$(ps_read "$WSP" "$PID" '.type')" = "\"plan\"" ]
}

@test "ps_read with -r flag returns unquoted" {
  ps_init "$WSP" "$PID" "p" "plan"
  [ "$(ps_read "$WSP" "$PID" '.type' -r)" = "plan" ]
}

@test "ps_update atomically modifies state and bumps updatedAt" {
  ps_init "$WSP" "$PID" "p" "plan"
  local sp; sp="$(ps_path "$WSP" "$PID")"
  local before; before="$(jq -r .updatedAt "$sp")"
  sleep 0.01
  ps_update "$WSP" "$PID" '.currentStage = "quick_plan"'
  local after; after="$(jq -r .updatedAt "$sp")"
  [ "$(jq -r .currentStage "$sp")" = "quick_plan" ]
  [ "$after" -gt "$before" ]
  ! ls "$WSP/.atelier/pipelines/$PID"/*.tmp* 2>/dev/null
}

@test "ps_update on missing pipeline-state.json dies" {
  run ps_update "$WSP" "$PID" '.x=1'
  [ "$status" -ne 0 ]
}

@test "ps_append_stage adds a stage entry with running status" {
  ps_init "$WSP" "$PID" "p" "plan"
  ps_append_stage "$WSP" "$PID" "quick_plan" "interactive" "quick-planning" "$WSP/.atelier/pipelines/$PID/01-plan.md"
  local sp; sp="$(ps_path "$WSP" "$PID")"
  [ "$(jq -r '.stages | length' "$sp")" = "1" ]
  [ "$(jq -r '.stages[0].stage' "$sp")" = "quick_plan" ]
  [ "$(jq -r '.stages[0].status' "$sp")" = "running" ]
  [[ "$(jq -r '.stages[0].assignedOutputPath' "$sp")" =~ /01-plan\.md$ ]]
  [ "$(jq -r '.stages[0].id' "$sp")" != "null" ]
  [ "$(jq -r '.stages[0].startedAt | type' "$sp")" = "number" ]
}

@test "ps_complete_stage sets verdict, outputPath, completedAt on most recent stage" {
  ps_init "$WSP" "$PID" "p" "plan"
  ps_append_stage "$WSP" "$PID" "quick_plan" "interactive" "quick-planning" "$WSP/.atelier/pipelines/$PID/01-plan.md"
  ps_complete_stage "$WSP" "$PID" "done" "$WSP/.atelier/pipelines/$PID/01-plan.md"
  local sp; sp="$(ps_path "$WSP" "$PID")"
  [ "$(jq -r '.stages[0].verdict' "$sp")" = "done" ]
  [ "$(jq -r '.stages[0].status' "$sp")" = "completed" ]
  [[ "$(jq -r '.stages[0].outputPath' "$sp")" =~ 01-plan\.md$ ]]
  [ "$(jq -r '.lastVerdict' "$sp")" = "done" ]
  [[ "$(jq -r '.lastOutputPath' "$sp")" =~ 01-plan\.md$ ]]
}

@test "ps_complete_stage with partial sets stage status idle" {
  ps_init "$WSP" "$PID" "p" "feature"
  ps_append_stage "$WSP" "$PID" "implement" "autonomous" "implementing-plans" ""
  ps_complete_stage "$WSP" "$PID" "partial" "$WSP/.atelier/pipelines/$PID/progress.md"
  [ "$(ps_read "$WSP" "$PID" '.stages[0].status' -r)" = "idle" ]
  [ "$(ps_read "$WSP" "$PID" '.lastVerdict' -r)" = "partial" ]
}

@test "ps_set_status completed populates completedAt" {
  ps_init "$WSP" "$PID" "p" "plan"
  ps_set_status "$WSP" "$PID" "completed"
  [ "$(ps_read "$WSP" "$PID" '.status' -r)" = "completed" ]
  [ "$(ps_read "$WSP" "$PID" '.completedAt | type' -r)" = "number" ]
}

@test "ps_set_status stuck stores error" {
  ps_init "$WSP" "$PID" "p" "plan"
  ps_set_status "$WSP" "$PID" "stuck" "fix attempt cap exceeded"
  [ "$(ps_read "$WSP" "$PID" '.status' -r)" = "stuck" ]
  [ "$(ps_read "$WSP" "$PID" '.error' -r)" = "fix attempt cap exceeded" ]
}

@test "ps_init rejects malformed pipeline-id (no traversal)" {
  run ps_init "$WSP" "../escape" "p" "plan"
  [ "$status" -ne 0 ]
}
