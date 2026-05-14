#!/usr/bin/env bats

setup() {
  TMP="$(mktemp -d)"
  ATELIER_FAKE="$TMP/atelier"
  PLUGIN="$TMP/atelier-cc"
  mkdir -p "$ATELIER_FAKE/skills/foo" "$PLUGIN/skills" "$PLUGIN/scripts" "$PLUGIN/lib"
  echo "FOO V1" > "$ATELIER_FAKE/skills/foo/SKILL.md"
  cp "$BATS_TEST_DIRNAME/../../scripts/sync-skills.sh" "$PLUGIN/scripts/"
  cp "$BATS_TEST_DIRNAME/../../lib/common.sh" "$PLUGIN/lib/"
  chmod +x "$PLUGIN/scripts/sync-skills.sh"
  cd "$PLUGIN"
}
teardown() { rm -rf "$TMP"; }

@test "sync copies new skills" {
  ./scripts/sync-skills.sh
  [ "$(cat skills/foo/SKILL.md)" = "FOO V1" ]
}

@test "sync updates changed skills" {
  ./scripts/sync-skills.sh
  echo "FOO V2" > "$ATELIER_FAKE/skills/foo/SKILL.md"
  ./scripts/sync-skills.sh
  [ "$(cat skills/foo/SKILL.md)" = "FOO V2" ]
}

@test "sync removes skills that no longer exist upstream" {
  ./scripts/sync-skills.sh
  rm -rf "$ATELIER_FAKE/skills/foo"
  ./scripts/sync-skills.sh
  [ ! -d skills/foo ]
}

@test "sync is idempotent (diff exits clean on second run)" {
  ./scripts/sync-skills.sh
  ./scripts/sync-skills.sh
  diff -r "$ATELIER_FAKE/skills" skills
}
