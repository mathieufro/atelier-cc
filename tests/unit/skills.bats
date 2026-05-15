#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "skill_resolve returns plugin default when no user-local override" {
  run skill_resolve "writing-plans"
  [ "$status" -eq 0 ]
  [ "$output" = "$ATELIER_CC_ROOT/skills/writing-plans/SKILL.md" ]
}

@test "skill_resolve prefers user-local skill over plugin default" {
  mkdir -p "$HOME/.atelier/skills/writing-plans"
  echo "custom body" > "$HOME/.atelier/skills/writing-plans/SKILL.md"
  run skill_resolve "writing-plans"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.atelier/skills/writing-plans/SKILL.md" ]
}

@test "skill_resolve resolves a user-only skill that doesn't exist in plugin" {
  mkdir -p "$HOME/.atelier/skills/bookkeep-csv"
  echo "user-only" > "$HOME/.atelier/skills/bookkeep-csv/SKILL.md"
  run skill_resolve "bookkeep-csv"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.atelier/skills/bookkeep-csv/SKILL.md" ]
}

@test "skill_resolve dies on missing skill with both searched paths in error" {
  run skill_resolve "no-such-skill"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/.atelier/skills/no-such-skill/SKILL.md"* ]]
  [[ "$output" == *"$ATELIER_CC_ROOT/skills/no-such-skill/SKILL.md"* ]]
}

@test "skill_resolve rejects invalid skill name" {
  run skill_resolve "../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid skill name"* ]]
}

@test "skill_resolve rejects empty name" {
  run skill_resolve ""
  [ "$status" -ne 0 ]
}
