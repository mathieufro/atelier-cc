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

# Resolve $dir to an absolute pipeline directory. Accept three input shapes:
#   1. Path to a pipeline directory                (.../.atelier/pipelines/<id>)
#   2. Path to a file inside one                   (.../.atelier/pipelines/<id>/plan.md)
#   3. Bare pipeline id resolved against CWD's workspace
# CWD-based resolution is only the fallback for case 3 — we MUST derive the
# workspace from the resolved directory, not from CWD, so the attach can target
# a pipeline in a different workspace than the one the dispatcher is running in
# (e.g. monorepo CWD attaching into a sibling project's .atelier/pipelines/).
if [ -d "$dir" ]; then
  pdir="$(cd "$dir" && pwd -P)"
elif [ -f "$dir" ]; then
  pdir="$(cd "$(dirname "$dir")" && pwd -P)"
else
  cwd_wsp="$(find_workspace_root)"
  if [ -d "$cwd_wsp/.atelier/pipelines/$dir" ]; then
    pdir="$(cd "$cwd_wsp/.atelier/pipelines/$dir" && pwd -P)"
  else
    die "not a pipeline dir, file, or known id: $dir"
  fi
fi

pid="$(basename "$pdir")"
parent_abs="$(dirname "$pdir")"
[ "$(basename "$parent_abs")" = "pipelines" ] || die "$pdir is not under .atelier/pipelines/"
# wsp is the directory two levels above pdir: .../<wsp>/.atelier/pipelines/<id>
wsp="$(dirname "$(dirname "$parent_abs")")"
[ -d "$wsp/.atelier" ] || die "expected .atelier under derived workspace: $wsp"

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
