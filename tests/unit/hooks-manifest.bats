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
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    [[ "$cmd" == *'${CLAUDE_PLUGIN_ROOT}'* ]] || { echo "command does not use CLAUDE_PLUGIN_ROOT: $cmd" >&2; return 1; }
  done < <(jq -r '.. | .command? // empty' "$hf")
}

# Windows compatibility: on Windows, `bash` in cmd.exe/PowerShell resolves to
# C:\Windows\System32\bash.exe (the WSL launcher), not Git Bash. Hooks must
# therefore be invoked via run-hook.js, which detects Windows and explicitly
# finds Git Bash. node is reliably on PATH on all platforms (already required
# for the MCP server). The bare .sh path also fails on Windows (no file
# association), so this check catches both issues.
@test "every hook command is dispatched via run-hook.js (cross-platform)" {
  hf="$BATS_TEST_DIRNAME/../../hooks/hooks.json"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    [[ "$cmd" =~ ^node[[:space:]].*run-hook\.js ]] || {
      echo "hook command must use 'node ... run-hook.js ...' so it works on Windows without WSL: $cmd" >&2
      return 1
    }
  done < <(jq -r '.. | .command? // empty' "$hf")
}
