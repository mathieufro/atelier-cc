#!/usr/bin/env bats
load "${BATS_TEST_DIRNAME}/../fixtures/test-helpers.bash"

setup() {
  WSP_A="$(mktemp -d)"; mkdir "$WSP_A/.git"
  WSP_B="$(mktemp -d)"; mkdir "$WSP_B/.git"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
}
teardown() { rm -rf "$WSP_A" "$WSP_B"; }

@test "two workspaces with independent pipelines stay isolated" {
  cd "$WSP_A"; PID_A="$(CLAUDE_SESSION_ID=sess-A "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'A')"
  cd "$WSP_B"; PID_B="$(CLAUDE_SESSION_ID=sess-B "$ATELIER_CC_ROOT/scripts/start-pipeline.sh" 'B')"
  [ -d "$WSP_A/.atelier/pipelines/$PID_A" ] && [ ! -d "$WSP_A/.atelier/pipelines/$PID_B" ]
  [ -d "$WSP_B/.atelier/pipelines/$PID_B" ] && [ ! -d "$WSP_B/.atelier/pipelines/$PID_A" ]
  [ "$(find_owned_pipeline "$WSP_A" sess-A)" = "$PID_A" ]
  [ "$(find_owned_pipeline "$WSP_B" sess-B)" = "$PID_B" ]
  [ -z "$(find_owned_pipeline "$WSP_A" sess-B)" ]
  [ -z "$(find_owned_pipeline "$WSP_B" sess-A)" ]
}
