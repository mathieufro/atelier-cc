#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

input="$(cat 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] && cd "$cwd"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
wsp="$(find_workspace_root)"

pdir="$wsp/.atelier/pipelines"

[ -d "$pdir" ] || exit 0

HB_STALE_MS="${ATELIER_HEARTBEAT_STALE_MS:-120000}"
now_ms="$(epoch_ms)"
for sp in "$pdir"/*/pipeline-state.json; do
  [ -f "$sp" ] || continue
  pid="$(jq -r .id "$sp" 2>/dev/null)" || continue
  [ -n "$pid" ] && [ "$pid" != "null" ] || continue
  status="$(jq -r .status "$sp" 2>/dev/null)" || continue
  # Heartbeat-based crash recovery: demote running → idle only when the heartbeat
  # is stale (>120s). Preserves actively-running pipelines owned by parallel
  # sessions. Stuck pipelines stay stuck — set deliberately by routing.
  [ "$status" = "running" ] || continue
  hb="$(jq -r '.lastHeartbeatMs // .createdAt // 0' "$sp")"
  age=$((now_ms - hb))
  if [ "$age" -ge "$HB_STALE_MS" ]; then
    ps_update "$wsp" "$pid" \
      '.status = "idle" |
       .stages |= map(if .status == "running" then . + {status:"idle"} else . end)' \
      || continue
  fi
done

summaries=()
for sp in "$pdir"/*/pipeline-state.json; do
  [ -f "$sp" ] || continue
  status="$(jq -r .status "$sp" 2>/dev/null)" || continue
  if [ "$status" = "idle" ]; then
    owner="$(jq -r '.sourceSessionId // empty' "$sp" 2>/dev/null)"
    # Show pipelines owned by this session OR unowned legacy state files.
    # Other-session pipelines stay invisible to keep multi-session summaries clean.
    if [ -n "$session_id" ] && [ -n "$owner" ] && [ "$owner" != "$session_id" ]; then
      continue
    fi
    line="$(jq -r '"\(.id) — \(.prompt) (stage: \(.currentStage // "—"))"' "$sp" 2>/dev/null)" || continue
    summaries+=("$line")
  fi
done

[ "${#summaries[@]}" -gt 0 ] || exit 0
msg="You have ${#summaries[@]} idle Atelier pipeline(s):"
for s in "${summaries[@]}"; do msg+=$'\n  - '"$s"; done
msg+=$'\n\nResume with `/atelier resume <description>` or check status with `/atelier status`.'
jq -nc --arg m "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$m}}'
