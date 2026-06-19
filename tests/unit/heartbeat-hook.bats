#!/usr/bin/env bats
# PostToolUse heartbeat — re-injects the orchestrator's duty on a cadence so a
# long pipeline can't drift or forget what remains. Emits a non-blocking
# additionalContext JSON only when this session owns a running, autonomously-
# executing pipeline, throttled to every HEARTBEAT_EVERY tool calls.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/post-tool-use.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json>
  printf '{"id":"p1","type":"feature","task":"Build the format moat","sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"review_code","done":["brainstorm","implement"]}\n' \
    "$1" "$2" "$3" > "$SP"
}
drive() { printf '%s' "$1" | bash "$HOOK"; }

@test "running autonomous, cadence hit → injects task + ledger + definition-of-done" {
  mkstate sess-A running null
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]
  [[ "$output" == *"Build the format moat"* ]]
  [[ "$output" == *"remaining="* ]]
  [[ "$output" == *"DEFINITION OF DONE"* ]]
  [[ "$output" == *"validate"* ]]
}

@test "awaiting:user (interactive) → SILENT (no per-tool reminders during design)" {
  mkstate sess-A running '"user"'
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "awaiting:workflow → still beats (orchestrator is processing fan-out results)" {
  mkstate sess-A running '"workflow"'
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [[ "$output" == *"additionalContext"* ]]
}

@test "not owned by this session → SILENT (subagents/other sessions excluded)" {
  mkstate sess-A running null
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-B\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "terminal pipeline → SILENT" {
  mkstate sess-A complete null
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "throttled — speaks only every HEARTBEAT_EVERY calls, counter persists across calls" {
  mkstate sess-A running null
  export HEARTBEAT_EVERY=3
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"; [ -z "$output" ]   # 1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"; [ -z "$output" ]   # 2
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"                     # 3
  [[ "$output" == *"additionalContext"* ]]
}

@test "no owned pipeline at all → SILENT" {
  rm -rf "$TMP/.atelier"; mkdir -p "$TMP/.git"
  export HEARTBEAT_EVERY=1
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}
