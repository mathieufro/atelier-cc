#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  source "$BATS_TEST_DIRNAME/../../lib/routing.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  source "$BATS_TEST_DIRNAME/../../lib/dispatch.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  ROOT="$ATELIER_CC_ROOT"
  WSP="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  mkdir -p "$HOME/.atelier/skills/collect-x"
  cat > "$HOME/.atelier/skills/collect-x/SKILL.md" <<'EOF'
---
name: collect-x
---
# Collect X
USER-LOCAL-SKILL-MARKER
EOF
}

teardown() {
  rm -rf "$WSP" "$FAKE_HOME"
}

@test "dispatch_reemit_existing interactive branch embeds user-local skill body" {
  pid="test-pid-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{
  "id":"$pid","type":"acct","status":"running",
  "currentStage":"collect","lastVerdict":null,"stepCounter":1,
  "expectedSubagent":"atelier:atelier-stage-worker",
  "expectedMode":"interactive","expectedSkill":"collect-x",
  "stages":[{"id":"s1","stage":"collect","status":"running","mode":"interactive","skill":"collect-x","assignedOutputPath":"$WSP/.atelier/pipelines/$pid/01-acct-data.md"}],
  "fixAttempts":{}
}
EOF
  run dispatch_reemit_existing "$WSP" "$pid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER-LOCAL-SKILL-MARKER"* ]]
}

@test "dispatch_reemit_existing interactive: missing skill -> soft fallback preserved" {
  pid="test-fb-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{
  "id":"$pid","type":"acct","status":"running",
  "currentStage":"collect","lastVerdict":null,"stepCounter":1,
  "expectedSubagent":"atelier:atelier-stage-worker",
  "expectedMode":"interactive","expectedSkill":"definitely-not-a-skill",
  "stages":[{"id":"s1","stage":"collect","status":"running","mode":"interactive","skill":"definitely-not-a-skill"}],
  "fixAttempts":{}
}
EOF
  run dispatch_reemit_existing "$WSP" "$pid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skill body unavailable"* ]]
}
