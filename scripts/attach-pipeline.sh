#!/usr/bin/env bash
# Attach a NEW Atelier pipeline to an existing .atelier/pipelines/<id>/ directory.
# Used by the dispatcher's start-at-stage branch when the user references a plan/
# spec/etc that already lives inside a pipeline dir — adopting that dir keeps the
# new pipeline's state next to its source artifacts, instead of fragmenting into
# a sibling directory with a fresh random suffix.
#
# Writes pipeline-state.json in-place (overwrites if present — this script is for
# fresh attachment, not for resuming an already-managed pipeline; for that, use
# resume.sh / restart-stage.sh). Existing artifacts in the dir are untouched.
# Creates progress.md only if absent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

dir="${1:-}"; prompt="${2:-}"
[ -n "$dir" ] && [ -n "$prompt" ] || die "usage: attach-pipeline.sh <pipeline-dir-or-id> \"<prompt>\""
[ -n "${CLAUDE_SESSION_ID:-}" ] || die "CLAUDE_SESSION_ID env var is required"

wsp="$(find_workspace_root)"

# Accept either a bare pipeline id (e.g. 2026-05-14-foo-b8d2) or a path to a dir
# / file inside the pipeline dir. Normalize to the pipeline id.
if [ -d "$dir" ]; then
  pdir="$(cd "$dir" && pwd)"
elif [ -f "$dir" ]; then
  pdir="$(cd "$(dirname "$dir")" && pwd)"
elif [ -d "$wsp/.atelier/pipelines/$dir" ]; then
  pdir="$wsp/.atelier/pipelines/$dir"
else
  die "not a pipeline dir, file, or known id: $dir"
fi

pid="$(basename "$pdir")"
parent="$(basename "$(dirname "$pdir")")"
[ "$parent" = "pipelines" ] || die "$pdir is not under .atelier/pipelines/"

# Reuse ps_init: writes state.json into the dir, then we stamp ownership.
# pre-classify type stays null; the caller (dispatcher) will signal type +
# worktreeChoice + currentStage via mcp__atelier__atelier_signal next.
ps_init "$wsp" "$pid" "$prompt" ""
ps_update "$wsp" "$pid" '.sourceSessionId = $sid' --arg sid "$CLAUDE_SESSION_ID"

sp="$pdir/pipeline-state.json"
[ -f "$sp" ] || die "ps_init did not create $sp — refusing to continue"

if [ ! -f "$pdir/progress.md" ]; then
  cat > "$pdir/progress.md" <<'EOF'
# Progress

## Summary
- Total: 0 | Done: 0 | Remaining: 0

## Tasks

| # | Task | Status |
|---|------|--------|

## Iteration Log

EOF
fi

printf '%s\n' "$pid"
