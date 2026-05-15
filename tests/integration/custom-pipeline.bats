#!/usr/bin/env bats

FIXTURE="$BATS_TEST_DIRNAME/../fixtures/accounting-pipeline"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  WSP="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  for skill_dir in "$FIXTURE/skills"/*/; do
    name="$(basename "$skill_dir")"
    mkdir -p "$HOME/.atelier/skills/$name"
    cp "$skill_dir/SKILL.md" "$HOME/.atelier/skills/$name/SKILL.md"
  done
  mkdir -p "$WSP/.atelier/topologies"
  cp "$FIXTURE/accounting.json" "$WSP/.atelier/topologies/accounting.json"
  cp -R "$FIXTURE/sample-invoices" "$WSP/sample-invoices"
}

teardown() {
  rm -rf "$WSP" "$FAKE_HOME"
}

@test "accounting fixture has all 5 skills and 3 invoices" {
  for s in collect-invoices bookkeep-csv review-bookkeeping fix-bookkeeping insert-bookkeeping; do
    [ -f "$FIXTURE/skills/$s/SKILL.md" ]
  done
  count="$(ls "$FIXTURE/sample-invoices"/*.txt | wc -l | tr -d ' ')"
  [ "$count" -eq 3 ]
}

@test "custom topology loads and lists in topology_list" {
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  json="$(topology_load "$WSP" "accounting")"
  [ "$(printf '%s' "$json" | jq -r .name)" = "accounting" ]
  out="$(topology_list "$WSP")"
  [[ "$out" == *accounting* ]]
}

@test "skill_resolve finds every accounting skill user-local" {
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  for s in collect-invoices bookkeep-csv review-bookkeeping fix-bookkeeping insert-bookkeeping; do
    run skill_resolve "$s"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.atelier/skills/$s/SKILL.md" ]
  done
}

@test "compile-prompt emits custom skill body for autonomous accounting stage" {
  pid="acct-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{
  "id": "$pid",
  "type": "accounting",
  "status": "running",
  "prompt": "Process March 2026 invoices",
  "expectedSkill": "bookkeep-csv",
  "workspacePath": "$WSP",
  "stages": [{
    "id": "s1",
    "stage": "bookkeep_csv",
    "status": "running",
    "assignedOutputPath": "$WSP/.atelier/pipelines/$pid/02-acct-csv.md"
  }]
}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "bookkeep_csv"
  [ "$status" -eq 0 ]
  [[ "$output" == *"compte 6"* ]]
  [[ "$output" == *"Process March 2026 invoices"* ]]
}

@test "starting a pipeline with the accounting topology resolves every stage skill" {
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  json="$(topology_load "$WSP" "accounting")"
  for s in $(printf '%s' "$json" | jq -r '.stages[].skill'); do
    run skill_resolve "$s"
    [ "$status" -eq 0 ]
  done
}
