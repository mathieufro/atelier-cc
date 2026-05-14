#!/usr/bin/env bats

setup() {
  ATELIER_CC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  ATELIER_REPO="$ATELIER_CC_ROOT/../atelier"
  [ -d "$ATELIER_REPO" ] || skip "sibling atelier/ checkout not present"
  MONOREPO_ROOT="$ATELIER_CC_ROOT/.."
}

@test "after sync, plugin's skills/ is byte-equivalent to atelier/skills/ (modulo exclusion list)" {
  bash "$ATELIER_CC_ROOT/scripts/sync-skills.sh"
  # sync-skills.sh deliberately omits upstream skills that don't apply to the
  # CC plugin (see EXCLUDE in scripts/sync-skills.sh). Pass them as --exclude
  # to diff so the test reflects what sync actually promises.
  diff -r \
    --exclude=benchmarking \
    --exclude=ralph-loop-help \
    --exclude=responding \
    "$ATELIER_REPO/skills" "$ATELIER_CC_ROOT/skills"
}

@test "pre-commit installer creates an executable hook" {
  TMP_HOME="$(mktemp -d)/monorepo"
  mkdir -p "$TMP_HOME/.git/hooks" "$TMP_HOME/tools"
  cp "$MONOREPO_ROOT/tools/install-pre-commit.sh" "$TMP_HOME/tools/" 2>/dev/null || \
    skip "installer not in place"
  ATELIER_MONOREPO_ROOT="$TMP_HOME" bash "$TMP_HOME/tools/install-pre-commit.sh"
  [ -x "$TMP_HOME/.git/hooks/pre-commit" ]
  rm -rf "$TMP_HOME"
}

@test "pre-commit hook fails when skills drift (upstream changed, plugin not yet re-synced)" {
  [ -f "$MONOREPO_ROOT/tools/pre-commit.sh" ] || skip "hook script not in place"
  # Build a self-contained monorepo skeleton with a fake atelier source so we
  # can simulate "upstream skills changed; plugin's committed skills are stale."
  TMP_REPO="$(mktemp -d)"
  mkdir -p "$TMP_REPO/atelier/skills/foo" "$TMP_REPO/atelier-cc/scripts" "$TMP_REPO/atelier-cc/lib" "$TMP_REPO/atelier-cc/skills" "$TMP_REPO/tools"
  cp "$ATELIER_CC_ROOT/scripts/sync-skills.sh" "$TMP_REPO/atelier-cc/scripts/"
  cp "$ATELIER_CC_ROOT/lib/common.sh" "$TMP_REPO/atelier-cc/lib/"
  cp "$MONOREPO_ROOT/tools/pre-commit.sh" "$TMP_REPO/tools/"
  chmod +x "$TMP_REPO/atelier-cc/scripts/sync-skills.sh" "$TMP_REPO/tools/pre-commit.sh"
  # Establish a committed baseline.
  echo "BODY v1" > "$TMP_REPO/atelier/skills/foo/SKILL.md"
  bash "$TMP_REPO/atelier-cc/scripts/sync-skills.sh"
  ( cd "$TMP_REPO/atelier-cc" && git init -q && git add . && git -c user.email=t@t -c user.name=t commit -q -m "baseline" )
  # Drift the upstream skill — plugin's checked-in skills are now stale.
  echo "BODY v2" > "$TMP_REPO/atelier/skills/foo/SKILL.md"
  run bash "$TMP_REPO/tools/pre-commit.sh"
  rm -rf "$TMP_REPO"
  [ "$status" -ne 0 ]
}
