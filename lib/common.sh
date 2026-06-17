#!/usr/bin/env bash
# Minimal helpers for the atelier-cc anti-yield Stop hook — the ONLY scripted
# component in the workflow-era rewrite. Read-only: the orchestrator (an LLM)
# owns every state.json write (a single Write call). Nothing here
# mutates pipeline state.

# Bash version gate. Hooks run silently; a cryptic `declare: -A` failure midway
# would be hard to diagnose. Fail loudly at source-time. macOS ships bash 3.2;
# install bash 4+ via `brew install bash`.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "atelier-cc: bash 4+ required (running ${BASH_VERSION:-unknown}); install via 'brew install bash' on macOS" >&2
  exit 1
fi

die() { echo "atelier-cc: $*" >&2; exit 1; }

require_jq() { command -v jq >/dev/null 2>&1 || die "jq is required but not installed"; }

# Walk up from a directory to the workspace root (first ancestor containing
# .atelier/ or .git/). The orchestrator always runs with its cwd in the MAIN
# workspace (worktrees are used only for subagent code changes, and subagents
# fire SubagentStop — which this plugin does not hook — not the orchestrator's
# Stop), so walking up from the Stop hook's cwd lands on the right workspace.
find_workspace_root() {
  local dir="${1:-$PWD}"
  while [ "$dir" != "/" ] && [ -n "$dir" ]; do
    if [ -d "$dir/.atelier" ] || [ -d "$dir/.git" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  printf '%s\n' "${1:-$PWD}"
}

# Print the state.json path of the (at most one) pipeline this session owns and
# that is still running, else nothing. Ownership is keyed strictly on
# sourceSessionId == this session — NEVER a blind "only running pipeline"
# fallback (that was the old cross-session-hijack bug). The one-running-pipeline-
# per-session invariant (driver-enforced) makes the first match unambiguous.
find_owned_running_pipeline() {
  local wsp="$1" sid="$2"
  local pdir="$wsp/.atelier/pipelines"
  [ -d "$pdir" ] || return 0
  local sp owner status
  for sp in "$pdir"/*/state.json; do
    [ -f "$sp" ] || continue
    owner="$(jq -r '.sourceSessionId // empty' "$sp" 2>/dev/null)" || continue
    status="$(jq -r '.status // empty' "$sp" 2>/dev/null)" || continue
    if [ "$owner" = "$sid" ] && [ "$status" = "running" ]; then
      printf '%s\n' "$sp"
      return 0
    fi
  done
  return 0
}
