#!/usr/bin/env bats
# Anti-yield Stop hook — the one deterministic component (rewrite-spec §2.2).
# The hook always exits 0; a BLOCK is signalled by a {"decision":"block"} JSON on
# stdout, an ALLOW by no output.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/stop.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json>
  printf '{"id":"p1","type":"feature","sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"implement"}\n' "$1" "$2" "$3" > "$SP"
}
drive() { printf '%s' "$1" | bash "$HOOK"; }

@test "running + awaiting:null on the owned pipeline → BLOCK" {
  mkstate sess-A running null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"block"'* ]]
}

@test "awaiting:user → ALLOW (legitimate human wait)" {
  mkstate sess-A running '"user"'
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "awaiting:workflow → ALLOW (in-flight fan-out re-invokes)" {
  mkstate sess-A running '"workflow"'
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "status:complete → ALLOW (terminal)" {
  mkstate sess-A complete null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "status:failed → ALLOW (terminal — bounded retries exhausted)" {
  mkstate sess-A failed null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "different session → ALLOW (cross-session ownership firewall, no blind fallback)" {
  mkstate sess-A running null
  run drive "{\"session_id\":\"sess-B\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "stop_hook_active:true while running → STILL BLOCK (regression: must not short-circuit)" {
  # Claude Code sets stop_hook_active on every re-entry after a blocking Stop,
  # including the legitimate one after an Agent call. Keying an exit off it would
  # strand the pipeline after the first block. The state machine is the only guard.
  mkstate sess-A running null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"stop_hook_active\":true}"
  [[ "$output" == *'"block"'* ]]
}

@test "no owned running pipeline → ALLOW" {
  rm -rf "$TMP/.atelier"
  mkdir -p "$TMP/.git"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "block reason is self-contained (names pipeline, type, phase, driver path) for compaction recovery" {
  mkstate sess-A running null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [[ "$output" == *"p1"* ]]
  [[ "$output" == *"feature"* ]]
  [[ "$output" == *"implement"* ]]
  [[ "$output" == *"commands/atelier.md"* ]]
}
