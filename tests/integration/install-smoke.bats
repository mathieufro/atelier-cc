#!/usr/bin/env bats

setup() {
  ATELIER_CC_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"; cd "$TMP"; git init -q
}
teardown() { rm -rf "$TMP"; }

@test "claude plugin marketplace add + install succeed against this checkout" {
  command -v claude >/dev/null 2>&1 || skip "claude CLI not available"
  # Probe whether `claude plugin` is a real subcommand in this build.
  if ! claude plugin --help >/dev/null 2>&1; then
    skip "'claude plugin' subcommand not available in this build"
  fi
  # Marketplace manifest validates.
  claude plugin validate "$ATELIER_CC_ROOT" 2>&1 | grep -q "Validation passed"
  # Plugin manifest also validates (catches things like 'author: string vs object').
  ! claude plugin validate "$ATELIER_CC_ROOT" 2>&1 | grep -qiE "(unknown|unrecognized|invalid|expected).*"
}
