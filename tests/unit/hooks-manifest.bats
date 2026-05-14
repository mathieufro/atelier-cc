#!/usr/bin/env bats

@test "hooks.json declares Stop, SubagentStop, PreToolUse, SessionStart" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  jq -e '.hooks.Stop' "$hf" >/dev/null
  jq -e '.hooks.SubagentStop' "$hf" >/dev/null
  jq -e '.hooks.PreToolUse' "$hf" >/dev/null
  jq -e '.hooks.SessionStart' "$hf" >/dev/null
}

@test "PreToolUse hook is matcher-restricted to Agent tool" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  matcher="$(jq -r '.hooks.PreToolUse[0].matcher' "$hf")"
  [ "$matcher" = "Agent" ]
}

@test "all hook command paths use CLAUDE_PLUGIN_ROOT" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  for cmd in $(jq -r '.. | .command? // empty' "$hf"); do
    [[ "$cmd" == *'${CLAUDE_PLUGIN_ROOT}'* ]] || { echo "command does not use CLAUDE_PLUGIN_ROOT: $cmd" >&2; return 1; }
  done
}
