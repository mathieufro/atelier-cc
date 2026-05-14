#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

prompt="${1:-}"
[ -n "$prompt" ] || die "usage: start-pipeline.sh \"<prompt>\""
[ -n "${CLAUDE_SESSION_ID:-}" ] || die "CLAUDE_SESSION_ID env var is required"

wsp="$(find_workspace_root)"

slug="$(printf '%s' "$prompt" \
  | tr '[:upper:]' '[:lower:]' \
  | tr -c 'a-z0-9' '-' \
  | sed 's/--*/-/g; s/^-//; s/-$//' \
  | cut -d- -f1-5)"
[ -n "$slug" ] || slug="pipeline"

date_prefix="$(date +%Y-%m-%d)"

pid=""
for _ in 1 2 3 4 5; do
  rand4="$(printf '%04x' $((RANDOM % 65536)))"
  candidate="${date_prefix}-${slug}-${rand4}"
  if [ ! -d "$wsp/.atelier/pipelines/$candidate" ]; then
    pid="$candidate"
    break
  fi
done
[ -n "$pid" ] || die "could not allocate pipeline id"

# type is left null pre-classify; the dispatcher's atelier_signal sets it once
# the user picks a pipeline type via AskUserQuestion. Stop hook treats null type
# as "awaiting classify" and exits without routing.
ps_init "$wsp" "$pid" "$prompt" ""
ps_update "$wsp" "$pid" '.sourceSessionId = $sid' --arg sid "$CLAUDE_SESSION_ID"

# Post-condition: pipeline-state.json MUST exist after ps_init. If it doesn't,
# something is very wrong (filesystem, jq, lock contention) — fail loud rather
# than letting the caller proceed with a half-initialized pipeline.
sp="$wsp/.atelier/pipelines/$pid/pipeline-state.json"
[ -f "$sp" ] || die "ps_init did not create $sp — refusing to continue"

mkdir -p "$wsp/.atelier"

cat > "$wsp/.atelier/pipelines/$pid/progress.md" <<'EOF'
# Progress

## Summary
- Total: 0 | Done: 0 | Remaining: 0

## Tasks

| # | Task | Status |
|---|------|--------|

## Iteration Log

EOF

printf '%s\n' "$pid"
