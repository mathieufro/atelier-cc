#!/usr/bin/env bats
# Host contract (S37, S39): an embedding host (e.g. Liaison) sets ATELIER_*
# env names to run Atelier unattended. With ATELIER_AUTONOMY=autonomous the
# ask-guard denies every AskUserQuestion; without the env every hook prints
# exactly what it printed at the commit named in fixtures/golden/SOURCE.

setup() {
  unset ATELIER_AUTONOMY ATELIER_HOST ATELIER_HOST_DONE_TOOL ATELIER_HOST_NEEDS_YOU_TOOL ATELIER_HOST_FINISH
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/ask-guard.sh"
  GOLDEN="$BATS_TEST_DIRNAME/fixtures/golden"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json>
  printf '{"id":"p1","rung":2,"sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"brainstorm"}\n' "$1" "$2" "$3" > "$SP"
}
input() { printf '{"session_id":"sess-A","cwd":"%s","tool_name":"AskUserQuestion"}' "$TMP"; }

@test "S37: autonomous denies AskUserQuestion with awaiting:user" {
  mkstate sess-A running '"user"'
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  [[ "$output" == *"Atelier host contract"* ]]
  [[ "$output" == *"brief.md"* ]]
}

@test "S37: autonomous denies with no pipeline at all" {
  rm -rf "$TMP/.atelier"
  mkdir -p "$TMP/.git"
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  # also before any session id is known
  run bash -c 'printf "{}" | ATELIER_AUTONOMY=autonomous bash "$1"' _ "$HOOK"
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
}

@test "S37: the deny reason names ATELIER_HOST_NEEDS_YOU_TOOL when set, and omits a malformed value" {
  mkstate sess-A running '"user"'
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL=mcp__liaison__sessions_needs_you bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" == *"call mcp__liaison__sessions_needs_you with the reason"* ]]

  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous ATELIER_HOST_NEEDS_YOU_TOOL="rm -rf /; x" bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
  [[ "$reason" != *"rm -rf"* ]]
  [[ "$reason" == *'set awaiting:"user" with the reason in failure.reason'* ]]
  [[ "$reason" != *"call "* ]]

  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=autonomous bash "$2"' _ "$(input)" "$HOOK"
  reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  [[ "$reason" != *"call "* ]]
  [[ "$reason" == *'set awaiting:"user" with the reason in failure.reason'* ]]
}

@test "S37: ATELIER_AUTONOMY=guided or any other value changes nothing" {
  mkstate sess-A running '"user"'
  for v in guided Autonomous autonomous-x "" " autonomous"; do
    run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY="$3" bash "$2"' _ "$(input)" "$HOOK" "$v"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  mkstate sess-A running null
  run bash -c 'printf "%s" "$1" | ATELIER_AUTONOMY=guided bash "$2"' _ "$(input)" "$HOOK"
  [[ "$output" == *"full-autonomy contract"* ]]
  [[ "$output" != *"host contract"* ]]
}

@test "S39: without the env, ask-guard, stop, post-tool-use and session-start print exactly the golden output for each fixture state" {
  [ -f "$GOLDEN/SOURCE" ]
  [ "$(ls "$GOLDEN/out" | wc -l | tr -d ' ')" -eq 28 ]
  bash "$GOLDEN/run-hooks.sh" "$ROOT" "$TMP/out"
  run diff -r "$GOLDEN/out" "$TMP/out"
  [ "$status" -eq 0 ]
}
