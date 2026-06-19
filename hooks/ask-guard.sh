#!/usr/bin/env bash
# Atelier autonomy firewall — PreToolUse hook on AskUserQuestion.
#
# Companion to stop.sh. The Stop hook stops the orchestrator from YIELDING
# mid-autonomous-execution, but AskUserQuestion yields to the human through a
# tool call that never fires Stop — so without this guard the orchestrator can
# pop a question to the user in the middle of an autonomous stage (e.g. asking
# for deploy credentials at the end of the blueprint phase), silently breaking
# the full-autonomy contract. After the design stages there is NO escalation to
# the user: anything the user must provide (credentials, secrets, CLI auth,
# deploy targets) is elicited DURING speccing and recorded in the spec's
# "Prerequisites / Required Access" section.
#
# Same gate as stop.sh, keyed PURELY on the persisted state machine (state.json),
# never on tool_input:
#   DENY  when this session owns a pipeline that is status==running AND
#         awaiting==null  (genuinely mid-autonomous — no human in the loop).
#   ALLOW otherwise: no owned running pipeline (covers the §1a classify/worktree
#         questions, which run BEFORE state.json exists), a terminal pipeline, or
#         a legitimate interactive wait (awaiting user|workflow — the [I] design
#         conversation, during which AskUserQuestion is fine).
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
case "$status" in complete|failed) exit 0 ;; esac      # terminal → ALLOW
case "$awaiting" in user|workflow) exit 0 ;; esac       # legitimate human/fan-out wait → ALLOW

# status==running AND awaiting==null → mid-autonomous → DENY the question.
# Self-contained reason so a post-compaction orchestrator re-grounds itself and
# knows the autonomous response is DEFAULT-AND-ADVANCE, with FAIL as the rare
# last resort — never ASK.
pid="$(jq -r '.id // empty' "$sp" 2>/dev/null || true)"
phase="$(jq -r '.phase // empty' "$sp" 2>/dev/null || true)"
reason="Atelier full-autonomy contract: pipeline ${pid} is mid-autonomous execution at phase '${phase}' (status running, awaiting null). You may NOT ask the user — there is no human in the loop after the design stages. Almost always the right move is to DECIDE IT YOURSELF: take the sensible default (the most reasonable, reversible, convention-matching choice) and keep driving — a question you were about to ask is a decision you should make. status:\"failed\" is the LAST RESORT, only when you LEGITIMATELY CANNOT ADVANCE: a genuine hard blocker with no workable default — e.g. a required credential that is truly absent and nothing can substitute (it should have been captured in the spec's 'Prerequisites / Required Access' section during speccing). Only in that case write failure:{stage,reason,lastError} naming the blocker to ${sp} and stop. Do NOT fail for anything a sensible default would carry. (If this genuinely IS an interactive [I] design stage, you forgot to set awaiting:\"user\" in state.json first — set it, then ask.)"
jq -nc --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
