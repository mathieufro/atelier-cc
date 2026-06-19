#!/usr/bin/env bats
# Anti-yield + definition-of-done Stop hook (rewrite-spec §2.2). The hook always
# exits 0; a BLOCK is signalled by a {"decision":"block"} JSON on stdout, an
# ALLOW by no output.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/stop.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json> [done-json]
  printf '{"id":"p1","type":"feature","sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"implement","done":%s}\n' \
    "$1" "$2" "$3" "${4:-[]}" > "$SP"
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

@test "awaiting:workflow first sight → ALLOW and arms the staleness clock" {
  mkstate sess-A running '"workflow"'
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
  [ -f "$TMP/.atelier/pipelines/p1/.await-since" ]
}

@test "awaiting:workflow still fresh → ALLOW (under threshold)" {
  mkstate sess-A running '"workflow"'
  printf '%s\n' "$(date +%s)" > "$TMP/.atelier/pipelines/p1/.await-since"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "awaiting:workflow gone stale → BLOCK (workflow-strand gate, D2)" {
  mkstate sess-A running '"workflow"'
  printf '%s\n' "$(( $(date +%s) - 4000 ))" > "$TMP/.atelier/pipelines/p1/.await-since"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"block"'* ]]
  [[ "$output" == *"STALE"* ]]
}

@test "leaving awaiting:workflow (back to running/null) clears the staleness clock" {
  mkstate sess-A running null
  printf '%s\n' "$(date +%s)" > "$TMP/.atelier/pipelines/p1/.await-since"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [[ "$output" == *'"block"'* ]]
  [ ! -f "$TMP/.atelier/pipelines/p1/.await-since" ]
}

@test "status:complete WITH terminal stage done → ALLOW (terminal)" {
  mkstate sess-A complete null '["implement","review_code","simplify","e2e_gate","validate"]'
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ -z "$output" ]
}

@test "status:complete WITHOUT terminal stage in done → BLOCK (premature-complete gate, D1)" {
  mkstate sess-A complete null '["brainstorm","review_spec","write_plan","review_plan","implement"]'
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"block"'* ]]
  [[ "$output" == *"PREMATURE"* ]]
  [[ "$output" == *"validate"* ]]
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

@test "block reason is self-contained (names pipeline, type, phase, driver path, ledger) for compaction recovery" {
  mkstate sess-A running null
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [[ "$output" == *"p1"* ]]
  [[ "$output" == *"feature"* ]]
  [[ "$output" == *"implement"* ]]
  [[ "$output" == *"commands/atelier.md"* ]]
  [[ "$output" == *"remaining="* ]]
}

@test "completion gate honors persisted plan[] terminal stage over the type default" {
  printf '{"id":"p1","type":"feature","sourceSessionId":"sess-A","status":"complete","awaiting":null,"phase":"x","plan":["a","b","done_stage"],"done":["a","b"]}\n' > "$SP"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\"}"
  [[ "$output" == *'"block"'* ]]
  [[ "$output" == *"done_stage"* ]]
}
