#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
source "$ROOT/lib/topology.sh"
source "$ROOT/lib/routing.sh"
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
# We do NOT key off `input.stop_hook_active` because Claude Code sets that flag
# on every re-entry into the main loop after a blocking Stop hook — including
# the legitimate re-entry that follows an Agent tool call. Using the flag would
# strand the pipeline after the very first autonomous stage signals done.
last_status="$(printf '%s' "$state" | jq -r '(.stages // []) | (last // {}) | .status // ""')"
last_verdict="$(printf '%s' "$state" | jq -r '.lastVerdict // empty')"
if [ "$last_status" = "running" ] && [ -z "$last_verdict" ]; then
  exit 0
fi

type="$(printf '%s' "$state" | jq -r .type)"
# Awaiting classify: state was created but the dispatcher hasn't signaled a
# pipelineType yet. Don't dispatch — let the dispatcher's next turn complete.
if [ -z "$type" ] || [ "$type" = "null" ]; then
  exit 0
fi
topo="$(topology_load "$wsp" "$type" 2>/dev/null)" || {
  ps_set_status "$wsp" "$pid" "stuck" "topology not found or invalid: $type"
  exit 0
}

decision="$(routing_decide "$state" "$topo")"
kind="$(printf '%s' "$decision" | jq -r .kind)"

case "$kind" in
  terminate)
    ps_set_status "$wsp" "$pid" "completed"
    exit 0
    ;;
  pause)
    new_status="$(printf '%s' "$decision" | jq -r .newStatus)"
    err="$(printf '%s' "$decision" | jq -r '.error // ""')"
    ps_set_status "$wsp" "$pid" "$new_status" "$err"
    exit 0
    ;;
  dispatch)
    next_stage_json="$(printf '%s' "$decision" | jq -c .stage)"
    next_name="$(printf '%s' "$next_stage_json" | jq -r .name)"
    next_mode="$(printf '%s' "$next_stage_json" | jq -r .mode)"
    next_skill="$(printf '%s' "$next_stage_json" | jq -r '.skill // empty')"
    is_fix="$(printf '%s' "$decision" | jq -r .isFixStage)"
    parent_id="$(printf '%s' "$decision" | jq -r '.parentReviewStageId // empty')"
    inc="$(printf '%s' "$decision" | jq -r '.incrementFixAttempts // empty')"

    step="$(printf '%s' "$state" | jq -r .stepCounter)"
    next_step=$((step + 1))
    pad="$(printf '%02d' "$next_step")"
    slug="$(extract_topic_slug "$pid")"
    artifact_type="$(printf '%s' "$next_stage_json" | jq -r '.artifactType // empty')"
    requires="$(printf '%s' "$next_stage_json" | jq -r '.requiresArtifact // false')"
    assigned=""
    if [ "$is_fix" = "true" ] && [ -n "$parent_id" ]; then
      # Fix stages rewrite the upstream artifact in place (fix_spec→spec,
      # fix_plan→plan, etc.). Find the parent review's predecessor in the
      # topology and reuse its outputPath as the fix target. Falls back to the
      # synthesized NN-slug-stage path if anything is missing.
      parent_review_name="$(printf '%s' "$state" | jq -r --arg id "$parent_id" '
        (.stages // []) | map(select(.id == $id)) | first // {} | .stage // empty')"
      if [ -n "$parent_review_name" ]; then
        target_stage_name="$(printf '%s' "$topo" | jq -r --arg c "$parent_review_name" '
          (.stages | map(.name) | index($c)) as $i
          | if ($i != null and $i > 0) then .stages[$i - 1].name else empty end')"
        if [ -n "$target_stage_name" ]; then
          assigned="$(printf '%s' "$state" | jq -r --arg s "$target_stage_name" '
            [.stages[] | select(.stage == $s and (.outputPath // "") != "")] | last // {} | .outputPath // empty')"
        fi
      fi
    fi
    if [ -z "$assigned" ] && [ "$requires" = "true" ]; then
      if [ -n "$artifact_type" ]; then
        assigned="$wsp/.atelier/pipelines/$pid/${pad}-${slug}-${artifact_type}.md"
      else
        # Topology without artifactType — fall back to stage name so existing
        # custom topologies keep working.
        assigned="$wsp/.atelier/pipelines/$pid/${pad}-${slug}-${next_name}.md"
      fi
    fi

    ps_append_stage "$wsp" "$pid" "$next_name" "$next_mode" "$next_skill" "$assigned"
    if [ "$is_fix" = "true" ] && [ -n "$parent_id" ]; then
      ps_update "$wsp" "$pid" \
        '.stages |= (.[:-1] + [.[-1] + {dynamicallyInserted: true, parentReviewStageId: $pid}])' \
        --arg pid "$parent_id"
    fi
    if [ -n "$inc" ]; then
      ps_update "$wsp" "$pid" \
        '.fixAttempts[$k] = ((.fixAttempts[$k] // 0) + 1)' \
        --arg k "$inc"
    fi

    ps_update "$wsp" "$pid" ".lastVerdict = null | .expectedSubagent = \"atelier:atelier-stage-worker\""

    if [ "$next_mode" = "autonomous" ]; then
      reason="Call the Agent tool with subagent_type='atelier:atelier-stage-worker', description='atelier:$next_name', prompt='<MARKER:next-stage>'."
    else
      skill_file="$ROOT/skills/$next_skill/SKILL.md"
      if [ -f "$skill_file" ]; then
        skill_body="$(awk '
  NR==1 && /^---$/ {f=1; next}
  NR==1 && !/^---$/ {f=2; print; next}
  f==1 && /^---$/ {f=2; next}
  f==2 {print}
' "$skill_file")"
      else
        skill_body="(skill body unavailable)"
      fi
      output_block=""
      if [ -n "$assigned" ]; then
        output_block=$'## Output Path (REQUIRED)\n\nWrite your output artifact to this exact path — do not invent a different filename:\n\n  '"$assigned"$'\n\nWhen you signal `stage_complete`, pass this same path as `outputPath`.\n\n---\n\n'
      fi
      reason=$'You are entering the **'"$next_name"$'** stage.\n\n'"$output_block""$skill_body"$'\n\n---\n\nWhen this stage is done, call:\n\n```\nmcp__atelier__atelier_signal({type:"stage_complete", pipelineId:"'"$pid"$'", verdict:"...", outputPath:"..."})\n```\n\nThen stop your turn.'
    fi
    jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
    exit 0
    ;;
esac
