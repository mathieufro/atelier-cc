#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
source "$ROOT/lib/topology.sh"
require_jq
pid="${1:-}"; stage="${2:-}"; flag="${3:-}"
[ -n "$pid" ] && [ -n "$stage" ] || die "usage: restart-stage.sh <pipeline-id> <stage> [--reset-attempts]"
[ -n "${CLAUDE_SESSION_ID:-}" ] || die "CLAUDE_SESSION_ID env var is required"
# Stage name must be a plain identifier — never let arbitrary text into the jq filter.
[[ "$stage" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid stage name: $stage"
wsp="$(find_workspace_root)"
sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || die "pipeline not found: $pid"
# Validate the stage exists in the pipeline's topology (or is a synthesized
# fix_<review> name, which routing accepts but topology lookup doesn't list).
type="$(jq -r .type "$sp")"
if [ -n "$type" ] && [ "$type" != "null" ]; then
  topo="$(topology_load "$wsp" "$type" 2>/dev/null)" || die "topology not loadable: $type"
  if ! printf '%s' "$topo" | jq -e --arg s "$stage" '.stages[] | select(.name == $s)' >/dev/null; then
    # Allow fix_<review_name> synthesis used by routing's has_issues branch.
    review_name="${stage/fix_/review_}"
    if [ "$review_name" = "$stage" ] || \
       ! printf '%s' "$topo" | jq -e --arg s "$review_name" '.stages[] | select(.name == $s)' >/dev/null; then
      die "stage not found in topology $type: $stage"
    fi
  fi
fi
# Mark any trailing in-flight stage row as skipped before re-pointing currentStage.
# Without this, the Stop hook's stage-in-progress guard (last.status=="running"
# with empty lastVerdict) short-circuits and never dispatches the restart target.
ps_update "$wsp" "$pid" \
  '.stages |= (if (length > 0 and (.[-1].status == "running" or .[-1].status == "idle")) then
     (.[:-1] + [.[-1] + {status:"skipped", interrupted:true, error:"superseded by restart-stage"}])
   else . end)'

if [ "$flag" = "--reset-attempts" ]; then
  ps_update "$wsp" "$pid" \
    '.currentStage = $s | .lastVerdict = null | .status = "running" | .fixAttempts[$s] = 0 | .sourceSessionId = $sid' \
    --arg s "$stage" --arg sid "$CLAUDE_SESSION_ID"
else
  ps_update "$wsp" "$pid" \
    '.currentStage = $s | .lastVerdict = null | .status = "running" | .sourceSessionId = $sid' \
    --arg s "$stage" --arg sid "$CLAUDE_SESSION_ID"
fi
echo "- **Restart:** restart-stage to $stage at $(date -u +%FT%TZ)${flag:+ ($flag)}" \
  >> "$wsp/.atelier/pipelines/$pid/progress.md"
