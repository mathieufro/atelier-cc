#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
require_jq

# ── Why this hook exists ─────────────────────────────────────────────────────
# Autonomous stages are dispatched by handing the OWNER session a block
# directive: "Call the Agent tool with subagent_type='atelier:atelier-stage-
# worker', description='atelier:<stage>', prompt='<MARKER:next-stage>'". The
# token `atelier:atelier` collides with the user-invocable Skill named
# `atelier:atelier` (run/resume/status). The main agent sometimes resolves the
# directive by invoking that SKILL instead of calling the Agent TOOL. The skill
# then polls pipeline status and self-signals — which the staleness guard
# rejects (the worker never launched, so compiledPromptPath stays null) — and
# every Stop re-emit re-triggers the same misfire: an unbounded wedge.
#
# The Agent-dispatch budget in pretooluse-agent.sh cannot catch this: it is
# gated on matcher "Agent" and never sees a Skill call, so launchCount never
# increments and the cap never trips. This hook is the missing chokepoint for
# the Skill-misfire path: during a mid-flight autonomous dispatch it denies the
# orchestration skill, redirects to the Agent tool, and applies the same
# deterministic stuck-cap so the misfire path is bounded exactly like the
# Agent path.

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "Skill" ] || exit 0

skill_name="$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')"
# Only the orchestration skill drives the poll/self-signal loop. Other
# atelier:* skills (pipeline-create, etc.) are not the misfire and must pass.
[ "$skill_name" = "atelier:atelier" ] || [ "$skill_name" = "atelier" ] || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
[ -n "$session_id" ] || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] && cd "$cwd"
wsp="$(find_workspace_root)"
pid="$(find_owned_pipeline "$wsp" "$session_id")"
[ -n "$pid" ] || exit 0

sp="$(ps_path "$wsp" "$pid")"
[ -f "$sp" ] || exit 0

status="$(jq -r '.status // empty' "$sp")"
mode="$(jq -r '.expectedMode // empty' "$sp")"
stage="$(jq -r '.currentStage // empty' "$sp")"

# Act ONLY on the precise dispatch-pending ghost signature: an autonomous stage
# whose row is running with no verdict, no compiledPromptPath, no sessionId —
# i.e. the orchestrator is waiting for the main agent to call the Agent tool
# and the agent reached for this skill instead. In that exact state invoking
# the skill is always wrong. Any other state (stuck/idle/completed, interactive
# stage, or a worker genuinely running) → pass through so a user can still run
# `/atelier resume|status|abort` normally.
[ "$status" = "running" ] || exit 0
[ "$mode" = "autonomous" ] || exit 0

read -r last_stage last_status last_verdict last_compiled last_sid < <(jq -r '
  (.stages // []) | (last // {}) |
  [ (.stage // ""), (.status // ""), (.verdict // ""),
    (.compiledPromptPath // ""), (.sessionId // "") ] | @tsv' "$sp")
[ "$last_stage" = "$stage" ] || exit 0
[ "$last_status" = "running" ] || exit 0
[ -z "$last_verdict" ] || exit 0
[ -z "$last_compiled" ] || exit 0
[ -z "$last_sid" ] || exit 0

# Deterministic bound for the skill-misfire path, mirroring the Agent dispatch
# budget. Without it a denied agent that just ends its turn would loop:
# Stop → ghost re-emit → skill → deny → Stop → … with launchCount never moving.
CAP="${ATELIER_DISPATCH_CAP:-3}"
dc="$(jq -r '(.stages // []) | (last // {}) | (.skillDenyCount // 0)' "$sp")"
newdc=$((dc + 1))

if [ "$newdc" -gt "$CAP" ]; then
  diag="dispatch budget exhausted: stage \"$stage\" — the main agent invoked the atelier skill instead of calling the Agent tool $newdc times; paused to prevent an infinite skill-misfire loop"
  ps_update "$wsp" "$pid" \
    '.status = "stuck" | .error = $e |
     (.stages |= (.[:-1] + [.[-1] + {status:"stuck", error:$e, skillDenyCount:$n}]))' \
    --arg e "$diag" --argjson n "$newdc"
  jq -nc --arg s "$stage" --argjson n "$newdc" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("Atelier is now `stuck`: stage \($s) was driven into the atelier skill \($n) times instead of the Agent tool (a structural loop). The pipeline will NOT re-dispatch. Do NOT invoke this skill again. Run `/atelier resume <task>` to reset the budget and retry.")
    }
  }'
  exit 0
fi

ps_update "$wsp" "$pid" \
  '.stages |= (.[:-1] + [.[-1] + {skillDenyCount:$n}])' --argjson n "$newdc"

jq -nc --arg s "$stage" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: ("Do NOT invoke the atelier skill here — you are mid-pipeline and the \($s) stage worker has not been launched. Stages are launched with the Agent TOOL, never the Skill tool. Call the Agent tool now with subagent_type='\''atelier:atelier-stage-worker'\'', description='\''atelier:\($s)'\'', prompt='\''<MARKER:next-stage>'\''. The MOMENT that Agent call returns, END YOUR TURN — do not poll pipeline status, do not call atelier_signal, do not start the next stage; the orchestrator routes from your turn-end.")
  }
}'
exit 0
