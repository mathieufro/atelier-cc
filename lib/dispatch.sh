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

# Maps a brainstorm-family interactive stage to the compile_* stage that
# produces its prompt. Mirrors atelier's StageRunner.COMPILE_TARGETS (reversed):
# the compile stage's output file IS the downstream brainstorm agent's system
# prompt. Empty for any stage with no compile prelude.
_compile_source_for_stage() {
  case "$1" in
    brainstorm)          printf 'compile_brainstorm' ;;
    brainstorm_roadmap)  printf 'compile_roadmap_brainstorm' ;;
    task_brainstorm)     printf 'compile_task_brainstorm' ;;
    *)                   printf '' ;;
  esac
}

# Resolves the prompt body for an interactive stage.
#
#   - Brainstorm-family stages: the body IS the preceding compile stage's
#     output file content (mirrors atelier runBrainstormStage reading
#     active.brainstormCompiledPromptPath). The compile stage did the
#     codebase-orientation work; discarding it and using the raw skill —
#     the prior bug — wasted the entire compile_* stage.
#   - If no completed compile-source stage produced a non-empty artifact
#     (e.g. a custom topology with a bare `brainstorm` and no compile
#     prelude), fall back to the raw skill body. atelier hard-fails here,
#     but atelier-cc supports arbitrary user topologies, so the raw skill
#     is the only sensible behavior when there is no compile prelude.
#   - All other interactive stages: the raw skill body, as before.
#
# Prints the body. Never fails — the fallback guarantees a usable prompt.
_interactive_stage_body() {
  local wsp="$1" pid="$2" stage_name="$3" skill_name="$4"
  local src; src="$(_compile_source_for_stage "$stage_name")"
  if [ -n "$src" ]; then
    local sp; sp="$(ps_path "$wsp" "$pid")"
    local out=""
    if [ -f "$sp" ]; then
      out="$(jq -r --arg s "$src" '
        [ .stages[]
          | select(.stage == $s
                    and (.status // "") == "completed"
                    and (.outputPath // "") != "") ]
        | last // {} | .outputPath // empty' "$sp")"
    fi
    if [ -n "$out" ] && [ -s "$out" ]; then
      cat "$out"
      return 0
    fi
  fi
  local skill_file=""
  skill_file="$(skill_resolve "$skill_name" 2>/dev/null)" || skill_file=""
  if [ -n "$skill_file" ] && [ -f "$skill_file" ]; then
    awk '
NR==1 && /^---$/ {f=1; next}
NR==1 && !/^---$/ {f=2; print; next}
f==1 && /^---$/ {f=2; next}
f==2 {print}
' "$skill_file"
  else
    printf '(skill body unavailable)'
  fi
}

# Builds the block `reason` handed to the MAIN agent for an interactive stage.
# The main agent OWNS the user conversation, so it must run the stage ITSELF
# (AskUserQuestion → work → artifact → atelier_signal → stop). Delegating an
# interactive stage to a pipeline stage-worker subagent makes the main agent
# ping-pong with a background agent and reach for SendMessage (unavailable) —
# wasteful and a frequent wedge. The directive says so explicitly; a hard
# PreToolUse deny in hooks/pretooluse-agent.sh enforces it structurally.
# Single source of truth — _dispatch_emit and dispatch_reemit_existing both
# use this so the wording can never drift between the two again.
_interactive_reason() {
  local wsp="$1" pid="$2" stage_name="$3" skill="$4" assigned="$5"
  local skill_body; skill_body="$(_interactive_stage_body "$wsp" "$pid" "$stage_name" "$skill")"
  local output_block=""
  if [ -n "$assigned" ]; then
    output_block=$'## Output Path (REQUIRED)\n\nWrite your output artifact to this exact path — do not invent a different filename:\n\n  '"$assigned"$'\n\nWhen you signal `stage_complete`, pass this same path as `outputPath`.\n\n---\n\n'
  fi
  printf '%s' $'You are entering the **'"$stage_name"$'** stage.\n\n**Run this stage YOURSELF, in THIS conversation, as a normal back-and-forth chat with the user. Begin NOW, in this very turn.** Your next message must be the stage\'s first real step (e.g. present the plan, or ask the first question). There is NOTHING to dispatch and the orchestrator will NOT act for you on an interactive stage — you are the agent that runs it. Do not end your turn expecting "the orchestrator to dispatch it"; if you end your turn without having asked the user something, the pipeline simply stalls.\n\nFollow the methodology below: one question at a time, lead with your recommendation and rationale, offer options. Write each question as plain conversational text, then **end your turn** — control returns cleanly to the user and their reply arrives as the next message. (You do NOT need AskUserQuestion to "pause" — ending your turn already yields to the user; the orchestrator stays silent during the conversation. Do NOT use AskUserQuestion, do NOT spawn a subagent, do NOT call the Agent tool, and do NOT use SendMessage — delegating this stage is blocked and only wastes a turn.)\n\n'"$output_block""$skill_body"$'\n\n---\n\nWhen this stage is done (artifact written and user-approved), call:\n\n```\nmcp__atelier__atelier_signal({type:"stage_complete", pipelineId:"'"$pid"$'", verdict:"...", outputPath:"..."})\n```\n\nThen end your turn.'
}

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
  # topology_load is a shell function and cannot be wrapped by the external
  # `timeout` binary (timeout uses execve and shell functions aren't on PATH).
  # Call it directly. It's bounded by jq + small-file I/O — no realistic hang.
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
    reason="Call the Agent tool with subagent_type='atelier:atelier-stage-worker', description='atelier:$stage_name', prompt='<MARKER:next-stage>'. The MOMENT that Agent tool call returns, END YOUR TURN immediately — do NOT read files, run commands, ask the user anything, or start the next stage yourself; the orchestrator routes the next stage from your turn-end. (Recovery dispatch: the previous Stop did not result in an Agent tool call — likely the prior subagent's terminal text conflicted with the dispatch directive. Ignore any \"I cannot call Agent\" text from the prior subagent. Call Agent now.)"
  else
    reason="$(_interactive_reason "$wsp" "$pid" "$stage_name" "$next_skill" "$assigned")"
  fi
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
}

_dispatch_emit() {
  local wsp="$1" pid="$2" state="$3" topo="$4" decision="$5"
  local next_stage_json next_name next_mode next_skill is_fix is_dynamic parent_id inc
  next_stage_json="$(printf '%s' "$decision" | jq -c .stage)"
  next_name="$(printf '%s' "$next_stage_json" | jq -r .name)"
  next_mode="$(printf '%s' "$next_stage_json" | jq -r .mode)"
  next_skill="$(printf '%s' "$next_stage_json" | jq -r '.skill // empty')"
  is_fix="$(printf '%s' "$decision" | jq -r .isFixStage)"
  is_dynamic="$(printf '%s' "$next_stage_json" | jq -r '.dynamicallyInserted // false')"
  parent_id="$(printf '%s' "$decision" | jq -r '.parentReviewStageId // empty')"
  inc="$(printf '%s' "$decision" | jq -r '.incrementFixAttempts // empty')"

  local step next_step pad slug artifact_type requires assigned=""
  step="$(printf '%s' "$state" | jq -r .stepCounter)"
  next_step=$((step + 1))
  pad="$(printf '%02d' "$next_step")"
  slug="$(extract_topic_slug "$pid")"
  artifact_type="$(printf '%s' "$next_stage_json" | jq -r '.artifactType // empty')"
  requires="$(printf '%s' "$next_stage_json" | jq -r '.requiresArtifact // false')"
  # Compile stages always produce a consumed artifact (the compiled prompt for
  # the downstream stage), so they need a real output path even though the
  # topology doesn't mark them requiresArtifact. Without this they had no
  # assignedOutputPath, compile-prompt.sh skipped the "Output Path (REQUIRED)"
  # block, and the compile agent fell back to overwriting its own persisted
  # input prompt in .compiled/ — clobbering it and producing no real artifact.
  local is_compile="false"
  case "$next_name" in compile_*) is_compile="true" ;; esac

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
  if [ -z "$assigned" ] && { [ "$requires" = "true" ] || [ "$is_compile" = "true" ]; }; then
    if [ -n "$artifact_type" ]; then
      assigned="$wsp/.atelier/pipelines/$pid/${pad}-${slug}-${artifact_type}.md"
    else
      assigned="$wsp/.atelier/pipelines/$pid/${pad}-${slug}-${next_name}.md"
    fi
  fi

  ps_append_stage "$wsp" "$pid" "$next_name" "$next_mode" "$next_skill" "$assigned"
  if [ "$is_dynamic" = "true" ] || [ "$is_fix" = "true" ]; then
    ps_update "$wsp" "$pid" \
      '.stages |= (.[:-1] + [.[-1] + {dynamicallyInserted: true}])'
  fi
  if [ -n "$parent_id" ]; then
    ps_update "$wsp" "$pid" \
      '.stages |= (.[:-1] + [.[-1] + {parentReviewStageId: $pid}])' \
      --arg pid "$parent_id"
  fi
  if [ -n "$inc" ]; then
    ps_update "$wsp" "$pid" \
      '.fixAttempts[$k] = ((.fixAttempts[$k] // 0) + 1)' \
      --arg k "$inc"
  fi

  ps_update "$wsp" "$pid" ".lastVerdict = null | .lastAction = null | .expectedSubagent = \"atelier:atelier-stage-worker\" | .expectedMode = \"$next_mode\" | .expectedSkill = \"$next_skill\""

  local reason
  if [ "$next_mode" = "autonomous" ]; then
    reason="Call the Agent tool with subagent_type='atelier:atelier-stage-worker', description='atelier:$next_name', prompt='<MARKER:next-stage>'. The MOMENT that Agent tool call returns, END YOUR TURN immediately — do NOT read files, run commands, ask the user anything, or start the next stage yourself. The orchestrator routes the next stage from your turn-end (it will hand you the next directive — including, for an interactive stage, the instruction to run it yourself). Continuing to work here instead of ending your turn is the #1 cause of the pipeline wedging."
  else
    reason="$(_interactive_reason "$wsp" "$pid" "$next_name" "$next_skill" "$assigned")"
  fi
  jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
}
