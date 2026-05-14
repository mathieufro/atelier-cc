#!/usr/bin/env bats

@test "no SKILL.md exceeds 50KB" {
  ROOT="$BATS_TEST_DIRNAME/../.."
  oversized="$(find "$ROOT/skills" -name SKILL.md -size +50k 2>/dev/null)"
  if [ -n "$oversized" ]; then
    echo "Oversized SKILL.md files (>50KB):" >&2
    echo "$oversized" >&2
    return 1
  fi
}
