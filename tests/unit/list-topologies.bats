#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"; cd "$TMP"; mkdir .git
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  mkdir -p .atelier/topologies
  cat > .atelier/topologies/custom.json <<EOF2
{"name":"custom","description":"A custom one","stages":[{"name":"x","mode":"autonomous","skill":"y"}]}
EOF2
}
teardown() { rm -rf "$TMP"; }

@test "list-topologies shows project override" {
  output="$("$ATELIER_CC_ROOT/scripts/list-topologies.sh")"
  [[ "$output" == *"custom"$'\t'"A custom one"* ]]
}
