#!/usr/bin/env bash
# Shared dispatch: given a pipeline at a stage boundary, apply the routing
# decision (mutate state) and — for dispatch decisions — emit the Claude Code
# `{decision:"block",reason:...}` payload that hands the next stage's directive
# back to the main agent.
#
# Used by both stop.sh and subagent-stop.sh. Calling from SubagentStop lets us
# skip the otherwise-mandatory main-agent turn between subagent completion and
# next dispatch — that intermediate turn (the model emitting "Not applicable"
# and stopping so Stop can fire) can take minutes on large-context models.

# dispatch_apply <wsp> <pid>
#   Reads state, runs routing_decide, applies side effects (appends stage row,
#   sets status, etc.), and prints the block-decision JSON for dispatches.
#   No-op (silent) for verdicts/states that don't dispatch from this boundary.
#   Caller must have already sourced common.sh, pipeline-state.sh, topology.sh,
#   routing.sh and run require_jq.
dispatch_apply() {
  local wsp="$1" pid="$2"
  local sp; sp="$(ps_path "$wsp" "$pid")"
  [ -f "$sp" ] || return 0
  local state; state="$(cat "$sp")"

  local type
  type="$(printf '%s' "$state" | jq -r .type)"
  if [ -z "$type" ] || [ "$type" = "null" ]; then
    return 0
  fi
  local topo
  topo="$(topology_load "$wsp" "$type" 2>/dev/null)" || {
    ps_set_status "$wsp" "$pid" "stuck" "topology not found or invalid: $type"
    return 0
  }

  local decision; decision="$(routing_decide "$state" "$topo")"
  local kind; kind="$(printf '%s' "$decision" | jq -r .kind)"

  case "$kind" in
    terminate)
      ps_set_status "$wsp" "$pid" "completed"
      return 0
      ;;
    pause)
      local new_status err
      new_status="$(printf '%s' "$decision" | jq -r .newStatus)"
      err="$(printf '%s' "$decision" | jq -r '.error // ""')"
      ps_set_status "$wsp" "$pid" "$new_status" "$err"
      return 0
      ;;
    dispatch)
      _dispatch_emit "$wsp" "$pid" "$state" "$topo" "$decision"
      return 0
      ;;
  esac
}

_dispatch_emit() {
  local wsp="$1" pid="$2" state="$3" topo="$4" decision="$5"
  local next_stage_json next_name next_mode next_skill is_fix parent_id inc
  next_stage_json="$(printf '%s' "$decision" | jq -c .stage)"
  next_name="$(printf '%s' "$next_stage_json" | jq -r .name)"
  next_mode="$(printf '%s' "$next_stage_json" | jq -r .mode)"
  next_skill="$(printf '%s' "$next_stage_json" | jq -r '.skill // empty')"
  is_fix="$(printf '%s' "$decision" | jq -r .isFixStage)"
  parent_id="$(printf '%s' "$decision" | jq -r '.parentReviewStageId // empty')"
  inc="$(printf '%s' "$decision" | jq -r '.incrementFixAttempts // empty')"

  local step next_step pad slug artifact_type requires assigned=""
  step="$(printf '%s' "$state" | jq -r .stepCounter)"
  next_step=$((step + 1))
  pad="$(printf '%02d' "$next_step")"
  slug="$(extract_topic_slug "$pid")"
  artifact_type="$(printf '%s' "$next_stage_json" | jq -r '.artifactType // empty')"
  requires="$(printf '%s' "$next_stage_json" | jq -r '.requiresArtifact // false')"

  if [ "$is_fix" = "true" ] && [ -n "$parent_id" ]; then
    local parent_review_name target_stage_name
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

  local reason
  if [ "$next_mode" = "autonomous" ]; then
    reason="Call the Agent tool with subagent_type='atelier:atelier-stage-worker', description='atelier:$next_name', prompt='<MARKER:next-stage>'."
  else
    local skill_file="$ROOT/skills/$next_skill/SKILL.md"
    local skill_body
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
    local output_block=""
    if [ -n "$assigned" ]; then
      output_block=$'## Output Path (REQUIRED)\n\nWrite your output artifact to this exact path — do not invent a different filename:\n\n  '"$assigned"$'\n\nWhen you signal `stage_complete`, pass this same path as `outputPath`.\n\n---\n\n'
    fi
    reason=$'You are entering the **'"$next_name"$'** stage.\n\n'"$output_block""$skill_body"$'\n\n---\n\nWhen this stage is done, call:\n\n```\nmcp__atelier__atelier_signal({type:"stage_complete", pipelineId:"'"$pid"$'", verdict:"...", outputPath:"..."})\n```\n\nThen stop your turn.'
  fi
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
}
