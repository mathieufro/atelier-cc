#!/usr/bin/env bash
# Skill resolver: user-local overrides shadow plugin defaults by name.
# Mirrors lib/topology.sh's precedence pattern but for SKILL.md files.

_skills_plugin_root() {
  if [ -n "${ATELIER_CC_ROOT:-}" ]; then
    printf '%s\n' "$ATELIER_CC_ROOT"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  else
    local self; self="${BASH_SOURCE[0]}"
    printf '%s\n' "$(cd "$(dirname "$self")/.." && pwd)"
  fi
}

# skill_resolve <name> — prints absolute path to SKILL.md or dies.
# Resolution: $HOME/.atelier/skills/<name>/SKILL.md → <plugin>/skills/<name>/SKILL.md.
skill_resolve() {
  local name="${1:-}"
  [ -n "$name" ] || die "skill_resolve: name required"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid skill name: $name"
  local user="$HOME/.atelier/skills/$name/SKILL.md"
  local plugin; plugin="$(_skills_plugin_root)/skills/$name/SKILL.md"
  if [ -f "$user" ]; then
    printf '%s\n' "$user"
    return 0
  fi
  if [ -f "$plugin" ]; then
    printf '%s\n' "$plugin"
    return 0
  fi
  die "skill not found: $name (searched: $user, $plugin)"
}
