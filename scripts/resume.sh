#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq
pid="${1:-}"
[ -n "$pid" ] || die "usage: resume.sh <pipeline-id>"
[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || die "CLAUDE_CODE_SESSION_ID env var is required"
wsp="$(find_workspace_root)"
sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || die "pipeline not found: $pid"
# Drift-tolerant resume: in addition to flipping status, demote any trailing
# stage rows marked "running" OR "stuck" to "idle". Without this, routing's
# crash-detection (last row running/stuck + verdict=null) short-circuits to
# "pause stuck" forever and the pipeline can never re-dispatch. Resume is the
# explicit user signal to retry — clearing stuck here makes the subsequent
# Stop-hook dispatch proceed instead of immediately re-stucking. Normally
# SessionStart's crash-recovery handles running rows on stale-heartbeat
# pipelines, but drift can land us at (status=idle/stuck, last=running/stuck)
# via abort races, manual edits, or pre-existing state files.
# Clearing the trailing rows is NOT enough: routing_decide keys off the
# top-level lastVerdict/lastAction, not the rows. A pipeline parked by an
# escalation has lastVerdict="stuck" (or "partial"); leaving it set makes the
# very next Stop hook re-enter routing's `stuck)` branch and immediately
# re-park to idle — resume reports success but is structurally incapable of
# recovering a stuck pipeline (only restart-stage worked, because it nulls
# lastVerdict). Resume IS the explicit "retry / continue from progress.md"
# signal, so clear every stale terminal signal here too; routing's null-verdict
# branch then re-dispatches currentStage, and compile-prompt injects progress.md.
ps_update "$wsp" "$pid" \
  '.status = "running" | .error = null | .sourceSessionId = $sid |
   .lastVerdict = null | .lastAction = null | .lastOutcome = null |
   .stages |= map(if (.status == "running" or .status == "stuck") then . + {status:"idle", interrupted:true} else . end)' \
  --arg sid "$CLAUDE_CODE_SESSION_ID"
