#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq
guidance="${1:-}"
[ -n "$guidance" ] || die "usage: redirect.sh \"<guidance>\""
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || die "CLAUDE_CODE_SESSION_ID env var is required"
wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$CLAUDE_CODE_SESSION_ID")"
[ -n "$pid" ] || die "no active pipeline owned by session $CLAUDE_CODE_SESSION_ID"
target_session="$(ps_read "$wsp" "$pid" '.stages[-1].sessionId // empty' -r)"
now="$(epoch_ms)"
ps_update "$wsp" "$pid" \
  '.pendingRedirect = {guidance: $g, targetSessionId: (if $t == "" then null else $t end), createdAt: $now}' \
  --arg g "$guidance" \
  --arg t "${target_session:-}" \
  --argjson now "$now"
printf '%s\n' "$target_session"
