#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  WSP="$(mktemp -d)"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  # Back up any real plan.json so tests can overwrite it freely.
  if [ -f "$ATELIER_CC_ROOT/topologies/plan.json" ]; then
    cp "$ATELIER_CC_ROOT/topologies/plan.json" "$ATELIER_CC_ROOT/topologies/plan.json.bak"
  fi
}

teardown() {
  rm -rf "$WSP"
  for f in broken empty bad bad2 coll; do
    rm -f "$ATELIER_CC_ROOT/topologies/$f.json"
  done
  if [ -f "$ATELIER_CC_ROOT/topologies/plan.json.bak" ]; then
    mv "$ATELIER_CC_ROOT/topologies/plan.json.bak" "$ATELIER_CC_ROOT/topologies/plan.json"
  fi
}

@test "topology_load reads plugin default" {
  cat > "$ATELIER_CC_ROOT/topologies/plan.json" <<EOF
{"name":"plan","description":"Quick","stages":[{"name":"quick_plan","mode":"interactive","skill":"quick-planning"}]}
EOF
  json="$(topology_load "$WSP" "plan")"
  [ "$(echo "$json" | jq -r .name)" = "plan" ]
}

@test "topology_load prefers project override" {
  mkdir -p "$WSP/.atelier/topologies"
  cat > "$WSP/.atelier/topologies/plan.json" <<EOF
{"name":"plan","description":"Override","stages":[{"name":"x","mode":"autonomous","skill":"y"}]}
EOF
  json="$(topology_load "$WSP" "plan")"
  [ "$(echo "$json" | jq -r .description)" = "Override" ]
}

@test "topology_load dies on missing topology" {
  run topology_load "$WSP" "nonexistent"
  [ "$status" -ne 0 ]
}

@test "topology_list emits name\\tdescription per topology" {
  mkdir -p "$WSP/.atelier/topologies"
  cat > "$WSP/.atelier/topologies/custom.json" <<EOF
{"name":"custom","description":"Custom one","stages":[]}
EOF
  output="$(topology_list "$WSP")"
  [[ "$output" == *"custom"$'\t'"Custom one"* ]]
}

@test "topology_list project override shadows plugin by name" {
  mkdir -p "$WSP/.atelier/topologies"
  cat > "$WSP/.atelier/topologies/plan.json" <<EOF
{"name":"plan","description":"Overridden","stages":[{"name":"x","mode":"autonomous","skill":"y"}]}
EOF
  output="$(topology_list "$WSP")"
  count="$(echo "$output" | awk -F'\t' '$1=="plan"' | wc -l | tr -d ' ')"
  [ "$count" = "1" ]
  [[ "$output" == *"plan"$'\t'"Overridden"* ]]
}

@test "topology_first_stage returns first" {
  topo='{"stages":[{"name":"a"},{"name":"b"}]}'
  result="$(topology_first_stage "$topo")"
  [ "$(echo "$result" | jq -r .name)" = "a" ]
}

@test "topology_next_after returns next stage" {
  topo='{"stages":[{"name":"a"},{"name":"b"},{"name":"c"}]}'
  result="$(topology_next_after "$topo" "b")"
  [ "$(echo "$result" | jq -r .name)" = "c" ]
}

@test "topology_next_after returns empty when last" {
  topo='{"stages":[{"name":"a"},{"name":"b"}]}'
  result="$(topology_next_after "$topo" "b")"
  [ -z "$result" ]
}

@test "topology_stage returns named entry" {
  topo='{"stages":[{"name":"a","mode":"interactive"},{"name":"b","mode":"autonomous"}]}'
  result="$(topology_stage "$topo" "b")"
  [ "$(echo "$result" | jq -r .mode)" = "autonomous" ]
}

@test "topology_load rejects invalid JSON" {
  echo "not-json" > "$ATELIER_CC_ROOT/topologies/broken.json"
  run topology_load "$WSP" "broken"
  [ "$status" -ne 0 ]
}

@test "topology_load rejects empty stages array" {
  cat > "$ATELIER_CC_ROOT/topologies/empty.json" <<EOF
{"name":"empty","description":"","stages":[]}
EOF
  run topology_load "$WSP" "empty"
  [ "$status" -ne 0 ]
  [[ "$output" == *"non-empty"* ]]
}

@test "topology_load rejects stages missing required fields" {
  cat > "$ATELIER_CC_ROOT/topologies/bad.json" <<EOF
{"name":"bad","description":"","stages":[{"name":"x"}]}
EOF
  run topology_load "$WSP" "bad"
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires name, mode, skill"* ]]
}

@test "topology_load rejects bad mode value" {
  cat > "$ATELIER_CC_ROOT/topologies/bad2.json" <<EOF
{"name":"bad2","description":"","stages":[{"name":"a","mode":"weird","skill":"x"}]}
EOF
  run topology_load "$WSP" "bad2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interactive"* ]]
}

@test "topology_load rejects fix_X collision with synthesized review_X->fix_X" {
  cat > "$ATELIER_CC_ROOT/topologies/coll.json" <<EOF
{"name":"coll","description":"","stages":[
  {"name":"review_spec","mode":"autonomous","skill":"reviewing-specs","reviewBehavior":"fixing-specs"},
  {"name":"fix_spec","mode":"autonomous","skill":"fixing-specs"}
]}
EOF
  run topology_load "$WSP" "coll"
  [ "$status" -ne 0 ]
  [[ "$output" == *"collision"* ]]
}
