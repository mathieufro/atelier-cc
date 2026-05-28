#!/usr/bin/env bats

setup() { ROOT="$BATS_TEST_DIRNAME/../.."; }

@test "all four built-in topologies exist and parse" {
  for t in plan task feature epic; do
    [ -f "$ROOT/topologies/$t.json" ]
    jq -e . "$ROOT/topologies/$t.json" >/dev/null
  done
}

@test "feature topology has 16 stages" {
  count="$(jq '.stages | length' "$ROOT/topologies/feature.json")"
  [ "$count" -eq 16 ]
}

@test "epic topology has 8 stages" {
  [ "$(jq '.stages | length' "$ROOT/topologies/epic.json")" -eq 8 ]
}

@test "task topology has 8 stages" {
  [ "$(jq '.stages | length' "$ROOT/topologies/task.json")" -eq 8 ]
}

@test "plan topology has 3 stages and ends in plan_gate" {
  [ "$(jq '.stages | length' "$ROOT/topologies/plan.json")" -eq 3 ]
  [ "$(jq -r '.stages[-1].name' "$ROOT/topologies/plan.json")" = "plan_gate" ]
}

@test "every stage references a real skill directory (post-sync)" {
  bash "$ROOT/scripts/sync-skills.sh" || skip "sync requires sibling atelier/ checkout"
  # `tr -d '\r'`: on git-bash for Windows, jq output is CRLF-terminated and
  # internal \r survive the for-loop split, so $skill ends up as "plan-gate<CR>"
  # and the file-existence check fails on a path that's really there.
  for t in plan task feature epic; do
    for skill in $(jq -r '.stages[].skill' "$ROOT/topologies/$t.json" | tr -d '\r' | sort -u); do
      if [ ! -f "$ROOT/skills/$skill/SKILL.md" ]; then
        echo "topology $t references missing skill: $skill" >&2
        return 1
      fi
    done
  done
}

@test "review stages declare reviewBehavior" {
  for t in plan task feature epic; do
    review_stages="$(jq -r '.stages[] | select(.name | startswith("review_")) | .name' "$ROOT/topologies/$t.json" | tr -d '\r')"
    for r in $review_stages; do
      behavior="$(jq -r --arg r "$r" '.stages[] | select(.name==$r) | .reviewBehavior // ""' "$ROOT/topologies/$t.json")"
      if [ -z "$behavior" ]; then
        echo "$t/$r missing reviewBehavior" >&2
        return 1
      fi
    done
  done
}

@test "e2e_gate stage has gateBehavior: skip-to-validate" {
  [ "$(jq -r '.stages[] | select(.name=="e2e_gate") | .gateBehavior' "$ROOT/topologies/feature.json")" = "skip-to-validate" ]
}

@test "implement and e2e stages support partial" {
  for t in task feature; do
    [ "$(jq -r '.stages[] | select(.name=="implement") | .supportsPartial' "$ROOT/topologies/$t.json")" = "true" ]
  done
  [ "$(jq -r '.stages[] | select(.name=="e2e") | .supportsPartial' "$ROOT/topologies/feature.json")" = "true" ]
}
