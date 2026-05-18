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
agent_type="$(printf '%s' "$input" | jq -r '.agent_type // ""')"
agent_id="$(printf '%s' "$input" | jq -r '.agent_id // ""')"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd"
wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$session_id")"
[ -n "$pid" ] || exit 0

sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || exit 0

expected_subagent="$(jq -r '.expectedSubagent // empty' "$sp")"
expected_mode="$(jq -r '.expectedMode // empty' "$sp")"
# No dispatch has been recorded → this isn't an atelier-driven stage boundary.
[ -n "$expected_subagent" ] || exit 0

# Don't act on terminal pipelines. A subagent can end after the pipeline was
# completed/aborted/stuck — re-dispatching from here would resurrect it.
status="$(jq -r '.status // empty' "$sp")"
case "$status" in completed|idle|stuck) exit 0 ;; esac

pending="$(jq -r '.pendingRedirect // empty' "$sp")"
verdict="$(jq -r '.lastVerdict // empty' "$sp")"
last_interrupted="$(jq -r '.stages[-1].interrupted // false' "$sp")"
if [ -n "$pending" ] && [ -z "$verdict" ]; then
  log info "subagent stopped during user redirect; not marking stuck"
  exit 0
fi
if [ "$last_interrupted" = "true" ]; then
  log info "subagent stopped after user-initiated abort; not marking stuck"
  exit 0
fi

# ── A stage completion WAS recorded → advance, regardless of stage mode. ──────
# The MCP atelier_signal handler set lastVerdict and marked the last stage row
# completed. Whoever signaled — an autonomous stage worker, OR the final stage
# worker of an INTERACTIVE brainstorm-family stage that the main agent
# delegated to (and relayed AskUserQuestion answers by re-spawning) — the
# boundary is real. Dispatching here, from SubagentStop, means advancement
# NEVER depends on the main agent voluntarily ending its turn afterward (which
# it often doesn't — the recurring wedge). The block `reason` is delivered to
# the parent (main) agent per the SubagentStop contract, so the main reacts as
# if Stop had fired. Once a verdict exists the agent_type is irrelevant — the
# stage genuinely completed whatever ran it.
if [ -n "$verdict" ]; then
  out_path="$(jq -r '.lastOutputPath // empty' "$sp")"
  last_assigned="$(jq -r '.stages[-1].assignedOutputPath // empty' "$sp")"
  if [ -n "$last_assigned" ] && { [ -z "$out_path" ] || [ ! -f "$out_path" ]; }; then
    ps_update "$wsp" "$pid" \
      '.status = "stuck" | .error = "missing required artifact" |
       (.stages |= (.[:-1] + [.[-1] + {status:"stuck", error:"missing required artifact"}]))'
    exit 0
  fi
  ps_update "$wsp" "$pid" \
    '.stages |= (.[:-1] + [.[-1] + {sessionId: $sid}])' \
    --arg sid "$agent_id"
  dispatch_apply "$wsp" "$pid"
  exit 0
fi

# ── No verdict recorded. ─────────────────────────────────────────────────────
# Interactive stage in flight: the main agent runs brainstorm-family stages by
# delegating work to stage-worker subagents and relaying AskUserQuestion
# answers by re-spawning fresh ones. Those intermediate subagents legitimately
# end WITHOUT signaling — the stage is not done; the main agent keeps
# orchestrating. Marking stuck (or re-dispatching) here would be wrong. Also
# covers any unrelated helper subagent the main spawns mid-stage. No-op.
if [ "$expected_mode" != "autonomous" ]; then
  exit 0
fi

# Autonomous stage, no verdict: the worker either never launched (ghost
# dispatch — main ignored the block directive) or died mid-flight.
if [ "$agent_type" != "$expected_subagent" ]; then
  ps_update "$wsp" "$pid" '
    .status = "stuck" |
    .error = "PreToolUse fallback: wrong subagent dispatched (got \"" + $got + "\", expected \"" + $expected + "\")" |
    (.stages |= (.[:-1] + [.[-1] + {status:"stuck", error:("PreToolUse fallback: wrong subagent dispatched (got \"" + $got + "\", expected \"" + $expected + "\")")}]))' \
    --arg got "$agent_type" \
    --arg expected "$expected_subagent"
  exit 0
fi

last_compiled="$(jq -r '.stages[-1].compiledPromptPath // empty' "$sp")"
last_session_id="$(jq -r '.stages[-1].sessionId // empty' "$sp")"
if [ -z "$last_compiled" ] && [ -z "$last_session_id" ]; then
  # Ghost: dispatched (running row) but main never launched the Agent. Re-emit
  # the directive for the existing row rather than appending a new one.
  dispatch_reemit_existing "$wsp" "$pid"
  exit 0
fi

ps_update "$wsp" "$pid" \
  '.status = "stuck" | .error = "subagent terminated without signaling" |
   (.stages |= (.[:-1] + [.[-1] + {status:"stuck",error:"subagent terminated without signaling"}]))'
exit 0
