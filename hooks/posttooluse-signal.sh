#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
source "$ROOT/lib/topology.sh"
source "$ROOT/lib/skills.sh"
source "$ROOT/lib/routing.sh"
source "$ROOT/lib/dispatch.sh"
require_jq

input="$(cat)"

# Why this hook exists
# --------------------
# Pipeline advance is driven by a hook emitting the next stage's directive.
# For AUTONOMOUS stages the subagent calls atelier_signal and SubagentStop
# fires deterministically when it ends — robust. For INTERACTIVE stages
# (quick_plan, plan_gate, brainstorm-family, classify) the MAIN agent calls
# atelier_signal, and the ONLY thing that advances the pipeline is the Stop
# hook — which fires *only when the model voluntarily ends its turn*. After
# atelier_signal returns "STOP YOUR TURN IMMEDIATELY" a large-context model
# frequently keeps generating instead of ending the turn, so Stop never fires
# and the pipeline silently wedges until the user interrupts.
#
# PostToolUse fires deterministically the instant atelier_signal returns,
# regardless of whether the model then rambles. Running the same dispatch_apply
# here makes the interactive boundary as reliable as the autonomous one. Stop's
# existing mid-flight / ghost-recovery guard stays as the secondary net (it
# no-ops once this hook has appended the next running row).

# Act only on a SUCCESSFUL atelier_signal. Every MCP error path (pipeline not
# found, lock failure, missing artifact, worktree failure) returns text that
# does NOT contain this phrase; the success payload always does. Dispatching
# off an errored signal would mis-route from un-advanced state.
resp="$(printf '%s' "$input" | jq -c '.tool_response // empty' 2>/dev/null || true)"
case "$resp" in
  *"Stage signal received"*) : ;;
  *) exit 0 ;;
esac

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd"

wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$session_id")"
[ -n "$pid" ] || exit 0

sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || exit 0
state="$(cat "$sp")"
status="$(printf '%s' "$state" | jq -r .status)"
case "$status" in
  completed|idle|stuck) exit 0 ;;
esac

# Autonomous stages signal from inside a subagent; SubagentStop owns that
# transition (subagent-stop.sh requires expectedMode == "autonomous"). Acting
# here too would double-dispatch. This hook is the symmetric counterpart: it
# owns ONLY the non-autonomous boundary. Empty expectedMode is the pre-classify
# gate (also a main-agent signal) — handle it here too.
expected_mode="$(printf '%s' "$state" | jq -r '.expectedMode // empty')"
[ "$expected_mode" = "autonomous" ] && exit 0

dispatch_apply "$wsp" "$pid"
