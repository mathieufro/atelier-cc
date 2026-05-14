#!/usr/bin/env bats

setup() { ROOT="$BATS_TEST_DIRNAME/../.."; MF="$ROOT/.claude-plugin/plugin.json"; }

@test "plugin manifest exists and parses" {
  [ -f "$MF" ]
  jq -e . "$MF" >/dev/null
}

@test "plugin name is 'atelier'" {
  [ "$(jq -r .name "$MF")" = "atelier" ]
}

@test "manifest declares atelier_signal MCP server" {
  jq -e '.mcpServers."atelier"' "$MF" >/dev/null
  [ "$(jq -r '.mcpServers.atelier.command' "$MF")" = "node" ]
  [[ "$(jq -r '.mcpServers.atelier.args[0]' "$MF")" =~ mcp/server\.js$ ]]
}

@test "agents/atelier-stage-worker.md present" {
  [ -f "$ROOT/agents/atelier-stage-worker.md" ]
}

@test "commands/atelier.md present" {
  [ -f "$ROOT/commands/atelier.md" ]
}

@test "hooks/hooks.json present" {
  [ -f "$ROOT/hooks/hooks.json" ]
}

@test "skills directory present" {
  [ -d "$ROOT/skills" ]
}
