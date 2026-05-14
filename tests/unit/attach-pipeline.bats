#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  mkdir -p .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_SESSION_ID="sess-t"
  mkdir -p .atelier/pipelines/2026-05-14-existing-b8d2
  printf 'plan body\n' > .atelier/pipelines/2026-05-14-existing-b8d2/plan.md
  printf 'review body\n' > .atelier/pipelines/2026-05-14-existing-b8d2/plan-review.md
}
teardown() { rm -rf "$TMP"; }

@test "attach-pipeline writes state.json into existing dir, leaves artifacts intact" {
  pid="$("$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" .atelier/pipelines/2026-05-14-existing-b8d2 'finish phase 11')"
  [ "$pid" = "2026-05-14-existing-b8d2" ]
  [ -f ".atelier/pipelines/$pid/pipeline-state.json" ]
  # Existing artifacts not clobbered.
  grep -q "plan body" ".atelier/pipelines/$pid/plan.md"
  grep -q "review body" ".atelier/pipelines/$pid/plan-review.md"
  # State has the right shape: type=null pre-classify, sourceSessionId stamped.
  [ "$(jq -r .type ".atelier/pipelines/$pid/pipeline-state.json")" = "null" ]
  [ "$(jq -r .sourceSessionId ".atelier/pipelines/$pid/pipeline-state.json")" = "sess-t" ]
  [ "$(jq -r .prompt ".atelier/pipelines/$pid/pipeline-state.json")" = "finish phase 11" ]
}

@test "attach-pipeline accepts a file path inside the pipeline dir" {
  pid="$("$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" .atelier/pipelines/2026-05-14-existing-b8d2/plan.md 'x')"
  [ "$pid" = "2026-05-14-existing-b8d2" ]
  [ -f ".atelier/pipelines/$pid/pipeline-state.json" ]
}

@test "attach-pipeline accepts a bare pipeline id" {
  pid="$("$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" 2026-05-14-existing-b8d2 'x')"
  [ "$pid" = "2026-05-14-existing-b8d2" ]
  [ -f ".atelier/pipelines/$pid/pipeline-state.json" ]
}

@test "attach-pipeline creates progress.md when absent" {
  pid="$("$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" 2026-05-14-existing-b8d2 'x')"
  [ -f ".atelier/pipelines/$pid/progress.md" ]
  grep -q '^# Progress' ".atelier/pipelines/$pid/progress.md"
}

@test "attach-pipeline preserves existing progress.md" {
  printf 'pre-existing log\n' > .atelier/pipelines/2026-05-14-existing-b8d2/progress.md
  "$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" 2026-05-14-existing-b8d2 'x' >/dev/null
  grep -q "pre-existing log" .atelier/pipelines/2026-05-14-existing-b8d2/progress.md
}

@test "attach-pipeline rejects a path outside .atelier/pipelines/" {
  mkdir -p some-other-dir
  run "$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" some-other-dir 'x'
  [ "$status" -ne 0 ]
}

@test "attach-pipeline rejects an unknown id" {
  run "$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" 2026-05-14-nonexistent-zzzz 'x'
  [ "$status" -ne 0 ]
}

@test "attach-pipeline requires both args" {
  run "$ATELIER_CC_ROOT/scripts/attach-pipeline.sh"
  [ "$status" -ne 0 ]
  run "$ATELIER_CC_ROOT/scripts/attach-pipeline.sh" 2026-05-14-existing-b8d2
  [ "$status" -ne 0 ]
}
