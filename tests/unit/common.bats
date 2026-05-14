#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  TMPDIR_T="$(mktemp -d)"
}

teardown() { rm -rf "$TMPDIR_T"; }

@test "epoch_ms returns 13-digit integer" {
  result="$(epoch_ms)"
  [[ "$result" =~ ^[0-9]{13}$ ]]
}

@test "atomic_write writes file content" {
  atomic_write "$TMPDIR_T/out.txt" "hello"
  [ "$(cat "$TMPDIR_T/out.txt")" = "hello" ]
}

@test "atomic_write does not leave .tmp file on success" {
  atomic_write "$TMPDIR_T/out.txt" "hello"
  ! ls "$TMPDIR_T"/*.tmp 2>/dev/null
}

@test "atomic_write replaces existing file" {
  echo "old" > "$TMPDIR_T/out.txt"
  atomic_write "$TMPDIR_T/out.txt" "new"
  [ "$(cat "$TMPDIR_T/out.txt")" = "new" ]
}

@test "die exits 1 with message on stderr" {
  run bash -c "source $BATS_TEST_DIRNAME/../../lib/common.sh; die 'boom'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"boom"* ]]
}

@test "find_workspace_root walks up to .atelier or git" {
  mkdir -p "$TMPDIR_T/wsp/.atelier" "$TMPDIR_T/wsp/sub/sub2"
  cd "$TMPDIR_T/wsp/sub/sub2"
  result="$(find_workspace_root)"
  [ "$result" = "$TMPDIR_T/wsp" ]
}

@test "find_workspace_root falls back to PWD when no marker" {
  cd "$TMPDIR_T"
  result="$(find_workspace_root)"
  [ "$result" = "$TMPDIR_T" ]
}

@test "find_owned_pipeline returns empty when no pipelines exist" {
  cd "$TMPDIR_T"
  result="$(find_owned_pipeline "$TMPDIR_T" "sess-x" || true)"
  [ -z "$result" ]
}

@test "common.sh exits non-zero when sourced under bash 3.x" {
  [ -x "/bin/bash" ] || skip "no /bin/bash present"
  ver="$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')"
  [ "$ver" -lt 4 ] || skip "/bin/bash is bash 4+; gate not exercisable here"
  run /bin/bash -c "source $BATS_TEST_DIRNAME/../../lib/common.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"bash 4+ required"* ]]
}
