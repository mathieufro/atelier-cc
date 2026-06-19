#!/usr/bin/env bats
# SessionStart re-grounding — restores the orchestrator's duty after a context-
# losing event (compaction) or when a session resumes/starts with a pipeline
# still running. Emits a non-blocking additionalContext JSON; never writes state.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/session-start.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status>
  printf '{"id":"p1","type":"feature","task":"Build the format moat","sourceSessionId":"%s","status":"%s","awaiting":null,"phase":"review_code","done":["brainstorm","implement"]}\n' \
    "$1" "$2" > "$SP"
}
drive() { printf '%s' "$1" | bash "$HOOK"; }

@test "owned + running after compaction → full re-ground (task + ledger + driver path)" {
  mkstate sess-A running
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"source\":\"compact\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"additionalContext"* ]]
  [[ "$output" == *"still RUNNING"* ]]
  [[ "$output" == *"compact"* ]]
  [[ "$output" == *"Build the format moat"* ]]
  [[ "$output" == *"commands/atelier.md"* ]]
  [[ "$output" == *"remaining="* ]]
}

@test "owned + running on resume → re-ground names the resume source" {
  mkstate sess-A running
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"source\":\"resume\"}"
  [[ "$output" == *"resume"* ]]
}

@test "running but NOT owned → gentle resume nudge (no auto-adopt)" {
  mkstate sess-OTHER running
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"source\":\"startup\"}"
  [[ "$output" == *"additionalContext"* ]]
  [[ "$output" == *"/atelier resume p1"* ]]
  [[ "$output" != *"still RUNNING"* ]]
}

@test "no running pipeline → SILENT" {
  mkstate sess-A complete
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"source\":\"startup\"}"
  [ -z "$output" ]
}

@test "no .atelier at all → SILENT" {
  rm -rf "$TMP/.atelier"; mkdir -p "$TMP/.git"
  run drive "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"source\":\"startup\"}"
  [ -z "$output" ]
}
