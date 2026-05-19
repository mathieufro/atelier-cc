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
# Resume must do ONE of two opposite things depending on whether the current
# stage actually finished:
#
#  • Stage COMPLETED with a forward verdict (done/proceed/skip) but the pipeline
#    got parked anyway (e.g. SessionStart's heartbeat false-demotion of an
#    interactive stage). Resume must ADVANCE — preserve lastVerdict so routing's
#    done/proceed/skip branch moves to the NEXT stage. Clearing it here is what
#    made a resumed, already-approved brainstorm RE-RUN the whole brainstorm
#    (data-loss-grade bug).
#
#  • Stage did NOT complete forward — it crashed mid-run (row running/idle, no
#    verdict) or escalated (verdict has_issues at cap / stuck / partial). Resume
#    means RETRY: clear lastVerdict/lastAction/lastOutcome so routing's
#    null-verdict branch re-dispatches currentStage (compile-prompt injects
#    progress.md). Without this a stuck/capped pipeline re-parks forever.
#
# Discriminator: the last row for currentStage is `completed` AND its verdict is
# a forward verdict. has_issues/stuck/partial are escalations → retry semantics.
cur="$(jq -r '.currentStage // empty' "$sp")"
advance="$(jq -r --arg c "$cur" '
  [ .stages[]? | select(.stage == $c) ] | last // {}
  | if ((.status // "") == "completed"
        and ((.verdict // "") == "done" or (.verdict // "") == "proceed" or (.verdict // "") == "skip"))
    then "yes" else "no" end' "$sp")"

if [ "$advance" = "yes" ]; then
  # Forward-completed → keep the verdict, just un-park. Demote only genuinely
  # in-flight rows (running/stuck) — never the completed current-stage row.
  ps_update "$wsp" "$pid" \
    '.status = "running" | .error = null | .sourceSessionId = $sid |
     .stages |= map(if (.status == "running" or .status == "stuck") then . + {status:"idle", interrupted:true} else . end)' \
    --arg sid "$CLAUDE_CODE_SESSION_ID"
else
  # Incomplete / escalated → retry: clear stale terminal signals so routing's
  # null-verdict branch re-dispatches currentStage.
  ps_update "$wsp" "$pid" \
    '.status = "running" | .error = null | .sourceSessionId = $sid |
     .lastVerdict = null | .lastAction = null | .lastOutcome = null |
     .stages |= map(if (.status == "running" or .status == "stuck") then . + {status:"idle", interrupted:true} else . end)' \
    --arg sid "$CLAUDE_CODE_SESSION_ID"
fi
