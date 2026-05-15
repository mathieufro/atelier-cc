#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export CLAUDE_CODE_SESSION_ID="sess-t"
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  PID="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'build oauth')"
  backup_skill writing-plans
  cat > "$ATELIER_CC_ROOT/skills/writing-plans/SKILL.md" <<'EOF'
---
name: writing-plans
description: writes plans
---
# Writing Plans

Body of skill.
EOF
}
teardown() {
  rm -rf "$TMP"
  restore_skill writing-plans
}

@test "compile-prompt produces header with stage, pipeline, cwd" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"# Stage: write_plan"* ]]
  [[ "$output" == *"# Pipeline: $PID"* ]]
  [[ "$output" == *"# Working directory: $TMP"* ]]
}

@test "compile-prompt embeds task prompt" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"build oauth"* ]]
}

@test "compile-prompt embeds SKILL.md body with frontmatter stripped" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"Body of skill."* ]]
  [[ "$output" != *"description: writes plans"* ]]
}

@test "compile-prompt handles SKILL.md with no frontmatter" {
  cat > "$ATELIER_CC_ROOT/skills/writing-plans/SKILL.md" <<'EOF'
# No Frontmatter

Just a body.
EOF
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"# No Frontmatter"* ]]
  [[ "$output" == *"Just a body."* ]]
}

@test "compile-prompt embeds prior stage outputs" {
  ps_append_stage "$TMP" "$PID" "brainstorm" "interactive" "brainstorming-feature" ""
  ps_complete_stage "$TMP" "$PID" "done" "$TMP/.atelier/pipelines/$PID/01-spec.md"
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"brainstorm"* ]]
  [[ "$output" == *"01-spec.md"* ]]
}

@test "compile-prompt includes signaling instructions and partial fallback" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"atelier_signal"* ]]
  [[ "$output" == *"STOP YOUR TURN IMMEDIATELY"* ]]
  [[ "$output" == *"partial"* ]]
  [[ "$output" == *"progress.md"* ]]
}

@test "compile-prompt dies for missing skill" {
  ps_update "$TMP" "$PID" '.currentStage = "x" | .expectedSkill = "no-such-skill"'
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "x"
  [ "$status" -ne 0 ]
}

@test "compile-prompt injects RESUMING header when stage is being re-dispatched" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  ps_append_stage "$TMP" "$PID" "write_plan" "autonomous" "writing-plans" "$TMP/.atelier/pipelines/$PID/02-plan.md"
  ps_complete_stage "$TMP" "$PID" "partial" "$TMP/.atelier/pipelines/$PID/progress.md"
  ps_append_stage "$TMP" "$PID" "write_plan" "autonomous" "writing-plans" "$TMP/.atelier/pipelines/$PID/02-plan.md"
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" == *"RESUMING"* ]]
  [[ "$output" == *"progress.md"* ]]
  [[ "$output" == *"read it first"* ]]
}

@test "compile-prompt omits RESUMING header on first dispatch of a stage" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  ps_append_stage "$TMP" "$PID" "write_plan" "autonomous" "writing-plans" ""
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$output" != *"RESUMING"* ]]
}

@test "compile-prompt omits RESUMING on parent-review re-entry after successful fix loop" {
  ps_update "$TMP" "$PID" '.currentStage = "review_spec" | .expectedSkill = "writing-plans"'
  ps_append_stage "$TMP" "$PID" "review_spec" "autonomous" "writing-plans" ""
  ps_complete_stage "$TMP" "$PID" "has_issues" "$TMP/.atelier/pipelines/$PID/01-review.md"
  ps_append_stage "$TMP" "$PID" "fix_spec" "autonomous" "fixing-specs" ""
  ps_complete_stage "$TMP" "$PID" "done" "$TMP/.atelier/pipelines/$PID/02-fix.md"
  ps_append_stage "$TMP" "$PID" "review_spec" "autonomous" "writing-plans" ""
  output="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "review_spec")"
  [[ "$output" != *"RESUMING"* ]]
}

@test "compile-prompt embeds pipelineId into SIGNAL footer" {
  ps_update "$TMP" "$PID" '.currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$out" == *"pipelineId"* ]]
  [[ "$out" == *"\"$PID\""* ]]
}

@test "compile-prompt uses worktreePath when set (worktree mode)" {
  WT="$TMP/.atelier/pipelines/$PID/worktree"
  mkdir -p "$WT"
  ps_update "$TMP" "$PID" \
    '.currentStage = "write_plan" | .expectedSkill = "writing-plans" |
     .worktreeChoice = "worktree" | .worktreePath = $wt' \
    --arg wt "$WT"
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$out" == *"# Working directory: $WT"* ]]
}

@test "compile-prompt falls back to workspacePath when worktreePath is null (in-tree mode)" {
  ps_update "$TMP" "$PID" \
    '.currentStage = "write_plan" | .expectedSkill = "writing-plans" |
     .worktreeChoice = "in-tree" | .worktreePath = null'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$out" == *"# Working directory: $TMP"* ]]
}

@test "compile-prompt for compile_plan embeds writing-plans skill via <stage-skill-reference>" {
  ps_update "$TMP" "$PID" \
    '.type = "feature" | .currentStage = "compile_plan" | .expectedSkill = "compiling-plan"'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "compile_plan")"
  [[ "$out" == *"<stage-skill-reference>"* ]]
  [[ "$out" == *"</stage-skill-reference>"* ]]
  [[ "$out" == *"Body of skill."* ]]
  [[ "$out" == *"DO NOT FOLLOW"* ]]
}

@test "compile-prompt for non-compile stage omits <stage-skill-reference>" {
  ps_update "$TMP" "$PID" \
    '.type = "feature" | .currentStage = "write_plan" | .expectedSkill = "writing-plans"'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "write_plan")"
  [[ "$out" != *"<stage-skill-reference>"* ]]
}

@test "compile-prompt embeds user-local custom skill body for autonomous stage" {
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  mkdir -p "$HOME/.atelier/skills/bookkeep-csv"
  cat > "$HOME/.atelier/skills/bookkeep-csv/SKILL.md" <<'EOF'
---
name: bookkeep-csv
---
# Bookkeep
USER-CUSTOM-BOOKKEEP-MARKER
EOF
  mkdir -p "$TMP/.atelier/topologies"
  cat > "$TMP/.atelier/topologies/acct.json" <<EOF
{"name":"acct","description":"t","stages":[{"name":"bookkeep","mode":"autonomous","skill":"bookkeep-csv","artifactType":"csv","requiresArtifact":true}]}
EOF
  ps_update "$TMP" "$PID" '.type = "acct" | .currentStage = "bookkeep" | .expectedSkill = "bookkeep-csv"'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "bookkeep")"
  [[ "$out" == *"USER-CUSTOM-BOOKKEEP-MARKER"* ]]
  rm -rf "$FAKE_HOME"
}

@test "compile-prompt embeds user-local target-skill override for compile stages" {
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  mkdir -p "$HOME/.atelier/skills/writing-plans"
  cat > "$HOME/.atelier/skills/writing-plans/SKILL.md" <<'EOF'
---
name: writing-plans
---
# Custom Plan Writer
TARGET-SKILL-OVERRIDE-MARKER
EOF
  ps_update "$TMP" "$PID" \
    '.type = "feature" | .currentStage = "compile_plan" | .expectedSkill = "compiling-plan"'
  out="$("$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$PID" "compile_plan")"
  [[ "$out" == *"TARGET-SKILL-OVERRIDE-MARKER"* ]]
  rm -rf "$FAKE_HOME"
}
