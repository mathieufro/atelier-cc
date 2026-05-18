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

# Stage-in-progress guard: if a stage is already dispatched and the subagent
# (or main, for interactive stages) hasn't signaled yet, this Stop hook fire is
# a no-op — the LLM is mid-stage. We learn that from state: the last stage row
# is still "running" AND no verdict has been recorded. Reroute only when the
# subagent has signaled (verdict set) or the stage moved to idle/paused.
#
# This is also how we avoid double-dispatch when subagent-stop.sh has already
# routed and queued the next stage: it appends a new running row + clears
# lastVerdict, so by the time Stop fires (after the main agent's Agent tool
# call) the guard kicks in and Stop becomes a silent no-op.
#
# We do NOT key off `input.stop_hook_active` because Claude Code sets that flag
# on every re-entry into the main loop after a blocking Stop hook — including
# the legitimate re-entry that follows an Agent tool call. Using the flag would
# strand the pipeline after the very first autonomous stage signals done.
last_status="$(printf '%s' "$state" | jq -r '(.stages // []) | (last // {}) | .status // ""')"
last_verdict="$(printf '%s' "$state" | jq -r '.lastVerdict // empty')"
expected_mode="$(printf '%s' "$state" | jq -r '.expectedMode // empty')"
if [ "$last_status" = "running" ] && [ -z "$last_verdict" ]; then
  # Interactive stage mid-conversation. The main agent IS the brainstorm/plan
  # agent: it asks the user a question (conversationally — recommendation +
  # rationale + options, per the stage skill) and ENDS ITS TURN so the user
  # can reply. That turn-end is correct and expected, not a ghost. We must NOT
  # re-emit or block here — a block decision prevents the turn from ending, so
  # the user could never answer (this is exactly why the flow used to need
  # AskUserQuestion / a subagent). Advancement for an interactive stage happens
  # only when atelier_signal is finally called, which PostToolUse handles
  # (main-agent signal, no agent_id). Silent no-op while the conversation runs.
  if [ "$expected_mode" = "interactive" ]; then
    exit 0
  fi
  # Stage is mid-flight (subagent running, or interactive stage going). Don't
  # re-dispatch. EXCEPT: detect the "ghost stage" case where SubagentStop
  # dispatched the next stage (appended a running row, emitted a block reason)
  # but the main agent never called the Agent tool — typically because the
  # just-completed subagent's terminal text ("I cannot call the Agent tool
  # here — my stage_complete signal has already been emitted") conflicted
  # with the dispatch directive and the main echoed the subagent's wording
  # instead of acting. Without recovery the pipeline silently wedges here.
  #
  # A real running stage has either a compiledPromptPath (PreToolUse fired,
  # which only happens when main actually called Agent) or a sessionId (the
  # subagent has already stopped at least once). A ghost has neither.
  last_compiled="$(printf '%s' "$state" | jq -r '(.stages // []) | (last // {}) | .compiledPromptPath // ""')"
  last_session_id="$(printf '%s' "$state" | jq -r '(.stages // []) | (last // {}) | .sessionId // ""')"
  if [ -z "$last_compiled" ] && [ -z "$last_session_id" ]; then
    dispatch_reemit_existing "$wsp" "$pid"
    exit 0
  fi
  exit 0
fi

dispatch_apply "$wsp" "$pid"
