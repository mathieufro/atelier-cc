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

@test "PostToolUse hook matches the atelier_signal MCP tool (both naming forms)" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  matcher="$(jq -r '.hooks.PostToolUse[0].matcher' "$hf")"
  # Must match the canonical deployed name and the marketplace-namespaced name.
  [[ "mcp__atelier__atelier_signal" =~ $matcher ]]
  [[ "mcp__plugin_atelier_atelier__atelier_signal" =~ $matcher ]]
  cmd="$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$hf")"
  [[ "$cmd" == *'posttooluse-signal.sh'* ]]
}

@test "all hook command paths use CLAUDE_PLUGIN_ROOT" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  for cmd in $(jq -r '.. | .command? // empty' "$hf"); do
    [[ "$cmd" == *'${CLAUDE_PLUGIN_ROOT}'* ]] || { echo "command does not use CLAUDE_PLUGIN_ROOT: $cmd" >&2; return 1; }
  done
}
