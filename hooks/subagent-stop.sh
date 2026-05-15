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
[ -n "$expected_subagent" ] && [ "$expected_mode" = "autonomous" ] || exit 0

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

if [ "$agent_type" != "$expected_subagent" ]; then
  ps_update "$wsp" "$pid" '
    .status = "stuck" |
    .error = "PreToolUse fallback: wrong subagent dispatched (got \"" + $got + "\", expected \"" + $expected + "\")" |
    (.stages |= (.[:-1] + [.[-1] + {status:"stuck", error:("PreToolUse fallback: wrong subagent dispatched (got \"" + $got + "\", expected \"" + $expected + "\")")}]))' \
    --arg got "$agent_type" \
    --arg expected "$expected_subagent"
  exit 0
fi

if [ -z "$verdict" ]; then
  ps_update "$wsp" "$pid" \
    '.status = "stuck" | .error = "subagent terminated without signaling" |
     (.stages |= (.[:-1] + [.[-1] + {status:"stuck",error:"subagent terminated without signaling"}]))'
  exit 0
fi

out_path="$(jq -r '.lastOutputPath // empty' "$sp")"
last_assigned="$(jq -r '.stages[-1].assignedOutputPath // empty' "$sp")"
if [ -n "$last_assigned" ]; then
  if [ -z "$out_path" ] || [ ! -f "$out_path" ]; then
    ps_update "$wsp" "$pid" \
      '.status = "stuck" | .error = "missing required artifact"'
    exit 0
  fi
fi

ps_update "$wsp" "$pid" \
  '.stages |= (.[:-1] + [.[-1] + {sessionId: $sid}])' \
  --arg sid "$agent_id"

# Dispatch the next stage directly from SubagentStop instead of waiting for the
# main agent to take its own turn before Stop fires. Saves one full main-agent
# turn per autonomous stage transition — on large-context models that
# intermediate "Not applicable; the Stop hook handles it" turn can cost several
# minutes. The `reason` here is delivered to the parent (main) agent per the
# Claude Code SubagentStop hook contract, so it reacts as if Stop had fired.
dispatch_apply "$wsp" "$pid"
