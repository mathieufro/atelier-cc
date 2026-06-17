#!/usr/bin/env bash
# Atelier anti-yield Stop hook — the ONE scripted guarantee (rewrite-spec §2.2).
#
# Blocks the orchestrator from yielding mid-autonomous-execution. Gated PURELY on
# the persisted state machine (state.json), never on `stop_hook_active`: Claude
# Code sets that flag on every main-loop re-entry after a blocking Stop —
# including the legitimate re-entry after an Agent tool call returns — so keying
# an exit off it would strand the pipeline after the first block. (old stop.sh:46
# documented this; stop-hook.bats:44 is the regression test.)
#
# ALLOW (exit 0) when: this session owns no running pipeline · the pipeline is
# terminal (complete|failed) · it is legitimately waiting (awaiting user|workflow).
# BLOCK only when status==running AND awaiting==null (genuinely mid-autonomous).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
require_jq

input="$(cat)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$sid" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || true
wsp="$(find_workspace_root "${cwd:-$PWD}")"

sp="$(find_owned_running_pipeline "$wsp" "$sid")"
[ -n "$sp" ] || exit 0                       # no owned running pipeline → ALLOW

status="$(jq -r '.status // empty' "$sp" 2>/dev/null || true)"
awaiting="$(jq -r '.awaiting // empty' "$sp" 2>/dev/null || true)"
case "$status" in complete|failed) exit 0 ;; esac      # terminal → ALLOW the final stop
case "$awaiting" in user|workflow) exit 0 ;; esac      # legitimate wait → ALLOW

# status==running AND awaiting==null → mid-autonomous execution → BLOCK.
# Self-contained reason so a post-compaction orchestrator re-grounds itself.
pid="$(jq -r '.id // empty' "$sp" 2>/dev/null || true)"
ptype="$(jq -r '.type // empty' "$sp" 2>/dev/null || true)"
phase="$(jq -r '.phase // empty' "$sp" 2>/dev/null || true)"
reason="You are the Atelier orchestrator for pipeline ${pid} (type ${ptype}), mid-autonomous execution. Do NOT yield. Re-read the driver at ${ROOT}/commands/atelier.md and the pipeline state at ${sp}, then continue driving at phase '${phase}'. Update state.json (a single Write) as you advance."
jq -nc --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
