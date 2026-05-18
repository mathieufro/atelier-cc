#!/usr/bin/env bash
# Stop-hook routing decision tree. Pure function: (state, topology) -> decision JSON.
# No side effects. The Stop hook applies the returned decision via ps_update.

readonly ROUTING_FIX_ATTEMPT_CAP=5
readonly ROUTING_PARTIAL_CAP=5

routing_decide() {
  local state="$1" topo="$2"

  local current verdict action
  current="$(printf '%s' "$state" | jq -r '.currentStage')"
  verdict="$(printf '%s' "$state" | jq -r '.lastVerdict')"
  action="$(printf '%s' "$state" | jq -r '.lastAction // empty')"

  if [ "$current" = "null" ] || [ -z "$current" ]; then
    local first; first="$(topology_first_stage "$topo")"
    _routing_emit dispatch "$first" "" "" "running" ""
    return
  fi

  local cur_is_fix parent_review_id most_recent_id
  cur_is_fix="$(printf '%s' "$state" | jq -r --arg c "$current" '
    ((.stages // []) | map(select(.stage == $c)) | last // {}).dynamicallyInserted // false')"
  parent_review_id="$(printf '%s' "$state" | jq -r --arg c "$current" '
    ((.stages // []) | map(select(.stage == $c)) | last // {}).parentReviewStageId // empty')"
  most_recent_id="$(printf '%s' "$state" | jq -r --arg c "$current" '
    ((.stages // []) | map(select(.stage == $c)) | last // {}).id // empty')"

  local stage; stage="$(topology_stage "$topo" "$current" 2>/dev/null || true)"
  # Dynamically inserted fix stages don't appear in topology; missing $stage is
  # only an error for non-fix stages.
  if [ -z "$stage" ] && [ "$cur_is_fix" != "true" ]; then
    _routing_emit pause "null" "" "" "stuck" "current stage not in topology: $current"
    return
  fi

  local review_behavior gate_behavior supports_partial
  if [ -n "$stage" ]; then
    review_behavior="$(printf '%s' "$stage" | jq -r '.reviewBehavior // empty')"
    gate_behavior="$(printf '%s' "$stage" | jq -r '.gateBehavior // empty')"
    supports_partial="$(printf '%s' "$stage" | jq -r '.supportsPartial // false')"
  else
    # Dynamically inserted fix stages: synthesized as autonomous + supportsPartial.
    review_behavior=""
    gate_behavior=""
    supports_partial="true"
  fi

  if [ "$current" = "plan_gate" ]; then
    case "$action" in
      implement)
        local implement_stage
        implement_stage="$(jq -nc '{name:"implement", mode:"autonomous", skill:"implementing-plans", supportsPartial:true, dynamicallyInserted:true}')"
        _routing_emit dispatch "$implement_stage" "" "" "running" ""
        return
        ;;
      done)
        _routing_emit terminate "null" "" "" "completed" ""
        return
        ;;
    esac
  fi

  case "$verdict" in
    null|"")
      local last_status; last_status="$(printf '%s' "$state" | jq -r --arg c "$current" '
        ((.stages // []) | map(select(.stage == $c)) | last // {}).status // empty')"
      # A row marked "running" or "stuck" with a cleared verdict indicates a
      # crashed subagent (running = mid-flight death; stuck = subagent-stop.sh
      # already recorded it). Pause and wait for explicit resume — auto-retry
      # would loop forever on a deterministically-crashing subagent.
      # Other states (empty/idle/completed/skipped) with verdict=null mean the
      # prior run is terminal and someone (resume.sh, restart-stage.sh, manual
      # repair) has asked for a fresh dispatch — handle them uniformly so weird
      # states (e.g. restart-stage leaving currentStage pointing at a completed
      # row) self-recover instead of wedging the pipeline.
      if [ "$last_status" = "running" ] || [ "$last_status" = "stuck" ]; then
        _routing_emit pause "null" "" "" "stuck" "subagent terminated without signaling at $current (last stage status: $last_status)"
      elif [ "$cur_is_fix" = "true" ]; then
        # Fix stages aren't in the topology, so $stage is empty here. Synthesize
        # the same shape has_issues uses below — reading the fix skill from the
        # parent review's reviewBehavior. Without this, the empty $stage flowed
        # into _routing_emit and produced a stage row literally named "null".
        local parent_review_name="${current/fix_/review_}"
        local parent_stage; parent_stage="$(topology_stage "$topo" "$parent_review_name" 2>/dev/null || true)"
        local fix_skill=""
        if [ -n "$parent_stage" ]; then
          fix_skill="$(printf '%s' "$parent_stage" | jq -r '.reviewBehavior // empty')"
        fi
        local fix_stage; fix_stage="$(jq -nc \
          --arg n "$current" \
          --arg s "$fix_skill" \
          '{name:$n, mode:"autonomous", skill:$s, supportsPartial:true, dynamicallyInserted:true}')"
        _routing_emit dispatch "$fix_stage" "true" "$parent_review_id" "running" ""
      else
        _routing_emit dispatch "$stage" "" "" "running" ""
      fi
      ;;
    partial)
      if [ "$supports_partial" = "true" ]; then
        local attempts; attempts="$(printf '%s' "$state" | jq -r --arg s "$current" '(.fixAttempts[$s] // 0) | tostring')"
        if [ "${attempts:-0}" -ge "$ROUTING_PARTIAL_CAP" ]; then
          _routing_emit pause "null" "" "" "idle" "partial retry cap exceeded"
        else
          # $current is the increment key (slot 7), NOT parent_id (slot 4). The
          # previous "$stage" "" "$current" "running" "" call put $current in the
          # parent_id slot and left inc_attempts empty, so fixAttempts never
          # incremented on partial — and the retry cap was unreachable.
          _routing_emit dispatch "$stage" "" "" "running" "" "$current"
        fi
      else
        _routing_emit pause "null" "" "" "stuck" "partial verdict on non-partial stage: $current"
      fi
      ;;
    done|proceed)
      # After a fix stage, advance past the parent review to the next topology stage.
      # The fix agent's verdict supersedes re-review — looping back would just re-run
      # the same review that just triggered the fix.
      local pivot="$current"
      if [ "$cur_is_fix" = "true" ] && [ -n "$parent_review_id" ]; then
        pivot="$(printf '%s' "$state" | jq -r --arg id "$parent_review_id" '
          (.stages // []) | map(select(.id == $id)) | first | .stage')"
      fi
      local next; next="$(topology_next_after "$topo" "$pivot")"
      if [ -z "$next" ]; then
        _routing_emit terminate "null" "" "" "completed" ""
      else
        _routing_emit dispatch "$next" "" "" "running" ""
      fi
      ;;
    has_issues)
      if [ "$cur_is_fix" = "true" ]; then
        # A fix stage reporting STILL-unresolved issues must NEVER terminate
        # the pipeline. The old code fell through to topology_next_after — and
        # since synthesized fix_* stages aren't in the topology, next was empty
        # → terminate "completed": a silent false success with the review's
        # issues unresolved (the mit-relicensing bug). Re-dispatch the parent
        # review so the bounded review↔fix loop continues; the parent review's
        # own has_issues path enforces the fixAttempts cap and ultimately
        # pauses idle for a human. Never auto-complete past a failed fix.
        local pr_name=""
        if [ -n "$parent_review_id" ]; then
          pr_name="$(printf '%s' "$state" | jq -r --arg id "$parent_review_id" '
            (.stages // []) | map(select(.id == $id)) | first // {} | .stage // empty')"
        fi
        [ -n "$pr_name" ] || pr_name="${current/fix_/review_}"
        local pr_stage; pr_stage="$(topology_stage "$topo" "$pr_name" 2>/dev/null || true)"
        if [ -n "$pr_stage" ]; then
          _routing_emit dispatch "$pr_stage" "" "" "running" ""
        else
          _routing_emit pause "null" "" "" "idle" "fix stage $current reported unresolved issues; parent review $pr_name not in topology"
        fi
      elif [ -n "$review_behavior" ]; then
        local attempts; attempts="$(printf '%s' "$state" | jq -r --arg s "$current" '(.fixAttempts[$s] // 0) | tostring')"
        if [ "${attempts:-0}" -ge "$ROUTING_FIX_ATTEMPT_CAP" ]; then
          _routing_emit pause "null" "" "" "idle" "fix attempt cap exceeded for $current"
        else
          local fix_skill="$review_behavior"
          local fix_stage_name="${current/review_/fix_}"
          local fix_stage
          fix_stage="$(jq -n \
            --arg n "$fix_stage_name" \
            --arg s "$fix_skill" \
            '{name:$n, mode:"autonomous", skill:$s, supportsPartial:true, dynamicallyInserted:true}')"
          _routing_emit dispatch "$fix_stage" "true" "$most_recent_id" "running" "" "$current"
        fi
      else
        local next; next="$(topology_next_after "$topo" "$current")"
        if [ -z "$next" ]; then
          _routing_emit terminate "null" "" "" "completed" ""
        else
          _routing_emit dispatch "$next" "" "" "running" ""
        fi
      fi
      ;;
    skip)
      if [ "$gate_behavior" = "skip-to-validate" ]; then
        local validate_stage; validate_stage="$(topology_stage "$topo" "validate" 2>/dev/null || true)"
        if [ -z "$validate_stage" ]; then
          _routing_emit terminate "null" "" "" "completed" ""
        else
          _routing_emit dispatch "$validate_stage" "" "" "running" ""
        fi
      else
        local next; next="$(topology_next_after "$topo" "$current")"
        if [ -z "$next" ]; then _routing_emit terminate "null" "" "" "completed" ""
        else _routing_emit dispatch "$next" "" "" "running" ""; fi
      fi
      ;;
    stuck)
      _routing_emit pause "null" "" "" "idle" "subagent signaled stuck at $current"
      ;;
    *)
      _routing_emit pause "null" "" "" "stuck" "unknown verdict: $verdict"
      ;;
  esac
}

_routing_emit() {
  local kind="$1" stage_json="$2" is_fix="${3:-}" parent_id="${4:-}" new_status="${5:-running}" err="${6:-}" inc_attempts="${7:-}"
  jq -n \
    --arg kind "$kind" \
    --argjson stage "${stage_json:-null}" \
    --arg isFix "${is_fix:-false}" \
    --arg parent "${parent_id:-}" \
    --arg status "$new_status" \
    --arg err "$err" \
    --arg inc "$inc_attempts" \
    '{
      kind: $kind,
      stage: $stage,
      isFixStage: ($isFix == "true"),
      parentReviewStageId: (if $parent == "" then null else $parent end),
      newStatus: $status,
      error: (if $err == "" then null else $err end),
      incrementFixAttempts: (if $inc == "" then null else $inc end)
    }'
}
