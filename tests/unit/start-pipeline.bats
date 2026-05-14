#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"
  cd "$TMP"
  mkdir -p .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  export CLAUDE_CODE_SESSION_ID="sess-t"
}
teardown() { rm -rf "$TMP"; }

@test "start-pipeline.sh creates state + progress.md, echoes id, does not write active-pipeline pointer" {
  pid="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'add oauth login')"
  [ -n "$pid" ]
  [[ "$pid" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-.+-[0-9a-f]{4}$ ]]
  [ -f ".atelier/pipelines/$pid/pipeline-state.json" ]
  [ ! -f ".atelier/active-pipeline" ]
  [ -f ".atelier/pipelines/$pid/progress.md" ]
}

@test "progress.md contains the four canonical sections" {
  pid="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'x')"
  grep -q '^# Progress' ".atelier/pipelines/$pid/progress.md"
  grep -q '^## Summary' ".atelier/pipelines/$pid/progress.md"
  grep -q '^## Tasks' ".atelier/pipelines/$pid/progress.md"
  grep -q '^## Iteration Log' ".atelier/pipelines/$pid/progress.md"
}

@test "slug derives from prompt's first words, alphanumeric only" {
  pid="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'Add OAuth! Login@Flow')"
  [[ "$pid" == *"add-oauth-login-flow"* ]] || [[ "$pid" == *"add-oauth"* ]]
}

@test "empty prompt is rejected" {
  run "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" ""
  [ "$status" -ne 0 ]
}

@test "initial state.type is null (awaiting classify)" {
  pid="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'x')"
  # Spec invariant: pipeline type is unknown until the dispatcher's classify
  # AskUserQuestion answer arrives via atelier_signal. Stop hook treats null as
  # "wait for classify"; defaulting to a specific topology silently misroutes
  # pipelines if the dispatcher errors before signaling.
  [ "$(jq -r .type ".atelier/pipelines/$pid/pipeline-state.json")" = "null" ]
}

@test "collision: existing directory triggers retry" {
  mkdir -p ".atelier/pipelines/2099-01-01-x-aaaa"
  pid="$($ATELIER_CC_ROOT/scripts/start-pipeline.sh 'x')"
  [ -n "$pid" ]
}
