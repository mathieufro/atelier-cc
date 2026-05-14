#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
}
teardown() { rm -rf "$TMP"; }

@test "list-stages emits name<TAB>skill<TAB>mode rows for builtin topology" {
  run "$ATELIER_CC_ROOT/scripts/list-stages.sh" feature
  [ "$status" -eq 0 ]
  [[ "$output" == *"write_plan"$'\t'"writing-plans"$'\t'"autonomous"* ]]
  [[ "$output" == *"brainstorm"$'\t'"brainstorming-feature"$'\t'"interactive"* ]]
}

@test "list-stages prefers project topology override" {
  mkdir -p .atelier/topologies
  cat > .atelier/topologies/feature.json <<EOF2
{"name":"feature","description":"override","stages":[{"name":"only","mode":"autonomous","skill":"s"}]}
EOF2
  run "$ATELIER_CC_ROOT/scripts/list-stages.sh" feature
  [ "$status" -eq 0 ]
  [[ "$output" == "only"$'\t'"s"$'\t'"autonomous" ]]
}

@test "list-stages fails on unknown topology" {
  run "$ATELIER_CC_ROOT/scripts/list-stages.sh" no-such-topology
  [ "$status" -ne 0 ]
}

@test "list-stages requires an argument" {
  run "$ATELIER_CC_ROOT/scripts/list-stages.sh"
  [ "$status" -ne 0 ]
}
