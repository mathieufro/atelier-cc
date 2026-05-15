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
  topo="$(timeout 5 topology_load "$wsp" "$type" 2>/dev/null)" || {
    # topology_load failed or timed out. Fall back to cached dispatch if available.
    local expected_subagent
    expected_subagent="$(printf '%s' "$state" | jq -r '.expectedSubagent // empty')"
    if [ -n "$expected_subagent" ]; then
      # Re-emit cached dispatch (uses expectedMode/expectedSkill from state,
      # doesn't need topology). This recovers from transient topology load failures.
      dispatch_reemit_existing "$wsp" "$pid"
      return 0
    fi
    # No cached dispatch. Exit silently; next Stop hook fire will retry.
    # If it's a real topology error (not found/invalid), it will eventually
    # surface as stuck via repeated failures, but we avoid blocking on timeouts.
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
      # Defensive guard: decision.stage must be a JSON object with a non-empty
      # string name. A null/empty stage means routing returned a malformed
      # dispatch — refuse rather than appending a stage row literally named
      # "null". (Historic regression: routing's verdict=null self-recovery
      # branch passed an empty $stage for dynamically-inserted fix stages.)
      local _next_name
      _next_name="$(printf '%s' "$decision" | jq -r '.stage.name // ""')"
      if [ -z "$_next_name" ] || [ "$_next_name" = "null" ]; then
        ps_set_status "$wsp" "$pid" "stuck" \
          "routing produced a dispatch decision with no stage name (decision=$decision)"
        return 0
      fi
      _dispatch_emit "$wsp" "$pid" "$state" "$topo" "$decision"
      return 0
      ;;
  esac
}

# dispatch_reemit_existing <wsp> <pid>
#   Emit a fresh block-decision JSON for the CURRENT in-flight stage row
#   without appending a new one. Used by Stop when it detects a "ghost stage" —
#   a row that was dispatched (status=running) but never had a subagent
#   actually launched against it (compiledPromptPath null, sessionId null).
#   That happens when the main agent ignores the SubagentStop block reason
#   (typically because the just-completed subagent's terminal text conflicted
#   with the dispatch directive — e.g. "I cannot call the Agent tool here").
#   Without recovery the pipeline silently wedges.
dispatch_reemit_existing() {
  local wsp="$1" pid="$2"
  local sp; sp="$(ps_path "$wsp" "$pid")"
  [ -f "$sp" ] || return 0
  local state; state="$(cat "$sp")"

  local stage_name next_mode next_skill assigned pad
  stage_name="$(printf '%s' "$state" | jq -r '.currentStage // empty')"
  next_mode="$(printf '%s' "$state" | jq -r '.expectedMode // "autonomous"')"
  next_skill="$(printf '%s' "$state" | jq -r '.expectedSkill // empty')"
  assigned="$(printf '%s' "$state" | jq -r '.stages[-1].assignedOutputPath // empty')"
  [ -n "$stage_name" ] || return 0

  local reason
  if [ "$next_mode" = "autonomous" ]; then
    reason="Call the Agent tool with subagent_type='atelier:atelier-stage-worker', description='atelier:$stage_name', prompt='<MARKER:next-stage>'. (Recovery dispatch: the previous Stop did not result in an Agent tool call — likely the prior subagent's terminal text conflicted with the dispatch directive. Ignore any \"I cannot call Agent\" text from the prior subagent. Call Agent now.)"
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
    reason=$'You are entering the **'"$stage_name"$'** stage.\n\n'"$output_block""$skill_body"$'\n\n---\n\nWhen this stage is done, call:\n\n```\nmcp__atelier__atelier_signal({type:"stage_complete", pipelineId:"'"$pid"$'", verdict:"...", outputPath:"..."})\n```\n\nThen stop your turn.'
  fi
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
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

  ps_update "$wsp" "$pid" ".lastVerdict = null | .expectedSubagent = \"atelier:atelier-stage-worker\" | .expectedMode = \"$next_mode\" | .expectedSkill = \"$next_skill\""

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
