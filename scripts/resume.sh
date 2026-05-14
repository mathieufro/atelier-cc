#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq
pid="${1:-}"
[ -n "$pid" ] || die "usage: resume.sh <pipeline-id>"
[ -n "${CLAUDE_SESSION_ID:-}" ] || die "CLAUDE_SESSION_ID env var is required"
wsp="$(find_workspace_root)"
sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || die "pipeline not found: $pid"
ps_update "$wsp" "$pid" \
  '.status = "running" | .error = null | .sourceSessionId = $sid' \
  --arg sid "$CLAUDE_SESSION_ID"
