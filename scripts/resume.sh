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
# Drift-tolerant resume: in addition to flipping status, also demote any
# trailing/orphan stage rows still marked "running" to "idle". Without this,
# the Stop hook's stage-in-progress guard (last.status=="running" && empty
# verdict) short-circuits forever and the pipeline can never re-dispatch.
# Normally SessionStart's crash-recovery does this demotion, but it only runs
# on status="running" pipelines with stale heartbeat — drift can land us at
# (status=idle, stages[-1]=running) via abort races, manual edits, or
# pre-existing state files.
ps_update "$wsp" "$pid" \
  '.status = "running" | .error = null | .sourceSessionId = $sid |
   .stages |= map(if .status == "running" then . + {status:"idle", interrupted:true} else . end)' \
  --arg sid "$CLAUDE_CODE_SESSION_ID"
