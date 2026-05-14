#!/usr/bin/env bats

@test "repo has expected top-level layout" {
  for dir in commands agents skills topologies hooks mcp scripts lib tests; do
    if [ ! -d "$BATS_TEST_DIRNAME/../../$dir" ]; then
      echo "missing dir: $dir" >&2
      return 1
    fi
  done
}

@test "bats vendored submodule is checked out" {
  [ -x "$BATS_TEST_DIRNAME/../bats/bin/bats" ]
}

@test "package.json declares private: true" {
  grep -q '"private": *true' "$BATS_TEST_DIRNAME/../../package.json"
}
