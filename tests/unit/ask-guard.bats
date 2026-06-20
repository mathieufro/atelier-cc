#!/usr/bin/env bats
# Autonomy firewall — PreToolUse hook on AskUserQuestion. Companion to the Stop
# hook: the Stop hook blocks YIELDING mid-autonomous, this blocks ASKING the user
# mid-autonomous (AskUserQuestion never fires Stop, so it would otherwise slip
# past the contract). Same state-machine gate. The hook always exits 0; a DENY is
# signalled by a {"permissionDecision":"deny"} JSON on stdout, an ALLOW by no
# output.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  HOOK="$ROOT/hooks/ask-guard.sh"
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/.atelier/pipelines/p1"
  SP="$TMP/.atelier/pipelines/p1/state.json"
}
teardown() { rm -rf "$TMP"; }

mkstate() { # <sourceSessionId> <status> <awaiting-json>
  printf '{"id":"p1","type":"feature","sourceSessionId":"%s","status":"%s","awaiting":%s,"phase":"write_plan"}\n' "$1" "$2" "$3" > "$SP"
}
ask() { printf '%s' "$1" | bash "$HOOK"; }

@test "running + awaiting:null on the owned pipeline → DENY (mid-autonomous, no human)" {
  mkstate sess-A running null
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "awaiting:user → ALLOW (legitimate [I] design conversation)" {
  mkstate sess-A running '"user"'
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ -z "$output" ]
}

@test "awaiting:workflow → DENY (no pipeline state makes asking-during-workflow legal; Stop allows the yield, this does not)" {
  mkstate sess-A running '"workflow"'
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"deny"'* ]]
}

@test "REGRESSION: fan-out just returned, orchestrator asks before clearing awaiting → DENY (the real leak: review_code returns, awaiting still 'workflow', orchestrator asks the acceptance-bar question)" {
  # review_code [FO]: orchestrator set awaiting:"workflow" + yielded; the Workflow
  # completed and re-invoked it; it read the review result and reached for
  # AskUserQuestion BEFORE writing awaiting:null. The OLD allow-list (user|workflow)
  # let this through. It must now be denied, with the fix-to-meet-spec guidance.
  mkstate sess-A running '"workflow"'
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [[ "$output" == *'"deny"'* ]]
  [[ "$output" == *"MEET THE SPEC"* ]]
  [[ "$output" == *"acceptance bar"* ]]
}

@test "status:complete → ALLOW (terminal)" {
  mkstate sess-A complete null
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ -z "$output" ]
}

@test "status:failed → ALLOW (terminal)" {
  mkstate sess-A failed null
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ -z "$output" ]
}

@test "different session → ALLOW (cross-session ownership firewall)" {
  mkstate sess-A running null
  run ask "{\"session_id\":\"sess-B\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ -z "$output" ]
}

@test "no owned running pipeline → ALLOW (the §1a classify/worktree questions run before state.json exists)" {
  rm -rf "$TMP/.atelier"
  mkdir -p "$TMP/.git"
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [ -z "$output" ]
}

@test "deny reason is self-contained (pipeline, phase, default-and-advance primary, fail as last resort) for compaction recovery" {
  mkstate sess-A running null
  run ask "{\"session_id\":\"sess-A\",\"cwd\":\"$TMP\",\"tool_name\":\"AskUserQuestion\"}"
  [[ "$output" == *"p1"* ]]
  [[ "$output" == *"write_plan"* ]]
  # primary instruction is default-and-advance, not bail
  [[ "$output" == *"sensible default"* ]]
  [[ "$output" == *"LAST RESORT"* ]]
  # fail is the rare last resort, and it names the prerequisite escape hatch
  [[ "$output" == *"Prerequisites"* ]]
  [[ "$output" == *'failed'* ]]
}
