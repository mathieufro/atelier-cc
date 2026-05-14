#!/usr/bin/env bash
# Pipeline state helpers. State file format mirrors Atelier's PipelineStateData
# exactly (see atelier/server/src/orchestration/pipeline-state.ts:9-43).
#
# Concurrency model: write-temp-then-rename gives atomicity for each individual
# write, but it does NOT serialize concurrent writers — a reader may see a stale
# state and overwrite a parallel write's changes. v1 relies on Claude Code's
# runtime serializing hook invocations (Stop runs after MCP/SubagentStop, never
# during) and a single active pipeline per workspace. Multi-pipeline / parallel-
# subagent v1.x must add an flock(1) (Linux) / lockfile-via-mkdir (portable)
# guard around ps_update + ps_read.

# Compose path to a pipeline's state file (filename must match Atelier).
ps_path() {
  local wsp="$1" pid="$2"
  printf '%s/.atelier/pipelines/%s/pipeline-state.json\n' "$wsp" "$pid"
}

# Validate pipeline-id (alphanumeric + dash, no path traversal).
_ps_validate_id() {
  [[ "$1" =~ ^[A-Za-z0-9-]+$ ]] || die "invalid pipeline id: $1"
}

# Read a jq expression from state.json. Pass -r as 4th arg for raw output.
ps_read() {
  local wsp="$1" pid="$2" filter="$3" raw="${4:-}"
  _ps_validate_id "$pid"
  local sp; sp="$(ps_path "$wsp" "$pid")"
  [ -f "$sp" ] || die "pipeline state not found: $sp"
  if [ "$raw" = "-r" ]; then
    jq -r "$filter" "$sp"
  else
    jq "$filter" "$sp"
  fi
}

# Atomic update with jq expression. Always bumps .updatedAt.
# Extra args after the filter are passed verbatim to jq, so callers can supply
# --arg/--argjson to interpolate external values safely (never embed
# user-controlled strings directly into the filter — jq syntax breaks if the
# value contains a quote or backslash, and the half-written tmp file is left
# behind on failure).
ps_update() {
  local wsp="$1" pid="$2" filter="$3"
  shift 3
  _ps_validate_id "$pid"
  local sp; sp="$(ps_path "$wsp" "$pid")"
  [ -f "$sp" ] || die "pipeline state not found: $sp"
  local now; now="$(epoch_ms)"
  # BASHPID (not $$) so concurrent subshells don't share tmp filenames.
  local tmp="${sp}.tmp.${BASHPID:-$$}"
  ps_lock_acquire "$sp"
  # updatedAt + lastHeartbeatMs are pre-set to $now, then the caller's filter
  # runs — so an ordinary update auto-bumps the heartbeat, but a test (or
  # crash-recovery simulation) that explicitly assigns .lastHeartbeatMs wins.
  if ! jq "$@" "(.updatedAt = $now | .lastHeartbeatMs = $now) | $filter" "$sp" > "$tmp"; then
    rm -f "$tmp"
    ps_lock_release "$sp"
    die "jq update failed"
  fi
  mv "$tmp" "$sp"
  ps_lock_release "$sp"
}

# Initialize a brand-new state file with Atelier's PipelineStateData shape.
ps_init() {
  local wsp="$1" pid="$2" prompt="$3" type="${4:-}"
  _ps_validate_id "$pid"
  local sp; sp="$(ps_path "$wsp" "$pid")"
  mkdir -p "$(dirname "$sp")"
  local now; now="$(epoch_ms)"
  # type may be empty pre-classify; encode that as JSON null so Stop hook can
  # detect "awaiting classify" deterministically.
  local type_jq
  if [ -z "$type" ]; then
    type_jq='null'
  else
    type_jq="$(jq -Rn --arg t "$type" '$t')"
  fi
  local doc
  doc="$(jq -n \
    --arg id "$pid" \
    --arg prompt "$prompt" \
    --arg wsp "$wsp" \
    --argjson type "$type_jq" \
    --arg pdir ".atelier/pipelines/$pid" \
    --argjson now "$now" \
    '{
      id: $id,
      prompt: $prompt,
      workspacePath: $wsp,
      status: "running",
      currentStage: null,
      type: $type,
      fromPipelineId: null,
      fromStage: null,
      model: null,
      variant: null,
      createdAt: $now,
      updatedAt: $now,
      completedAt: null,
      error: null,
      pipelineDir: $pdir,
      title: null,
      stepCounter: 0,
      stages: [],
      fixAttempts: {},
      gitBranch: null,
      gitBaseBranch: null,
      gitBaseCommit: null,
      worktreePath: null,
      worktreeChoice: null,
      sourceSessionId: null,
      stageModels: {},
      stageModelsConfirmed: false,
      lastVerdict: null,
      lastOutputPath: null,
      lastAction: null,
      lastOutcome: null,
      pendingRedirect: null,
      lastHeartbeatMs: $now
    }')"
  local tmp="${sp}.tmp.${BASHPID:-$$}"
  ps_lock_acquire "$sp"
  printf '%s\n' "$doc" > "$tmp"
  mv "$tmp" "$sp"
  ps_lock_release "$sp"
}

# Append a new StageData entry to .stages. Generates a unique id.
ps_append_stage() {
  local wsp="$1" pid="$2" stage="$3" mode="$4" skill="$5" assigned="${6:-}"
  local sid; sid="${stage}-$(printf '%04x' $((RANDOM % 65536)))-$(epoch_ms)"
  local now; now="$(epoch_ms)"
  ps_update "$wsp" "$pid" '
    (.stepCounter += 1) | .stages += [{
       id: $sid,
       stage: $stage,
       sessionId: null,
       status: "running",
       compiledPromptPath: null,
       assignedOutputPath: (if $assigned == "" then null else $assigned end),
       outputPath: null,
       interrupted: false,
       error: null,
       startedAt: $now,
       completedAt: null
     }] | .currentStage = $stage | .expectedMode = $mode | .expectedSkill = $skill' \
    --arg sid "$sid" \
    --arg stage "$stage" \
    --arg mode "$mode" \
    --arg skill "$skill" \
    --arg assigned "$assigned" \
    --argjson now "$now"
}

# Complete the most recent stage with verdict + outputPath; mirror into top-level last* fields.
ps_complete_stage() {
  local wsp="$1" pid="$2" verdict="$3" outpath="${4:-}" action="${5:-}" outcome="${6:-}"
  local now; now="$(epoch_ms)"
  local stage_status
  if [ "$verdict" = "partial" ]; then stage_status="idle"; else stage_status="completed"; fi
  ps_update "$wsp" "$pid" '
    (.stages |= (
        if length > 0 then
          .[:-1] + [.[-1] + {
            verdict: $verdict,
            outputPath: (if $outpath == "" then null else $outpath end),
            completedAt: $now,
            status: $stage_status
          }]
        else . end
      )) |
      .lastVerdict = $verdict |
      .lastOutputPath = (if $outpath == "" then null else $outpath end) |
      .lastAction = (if $action == "" then null else $action end) |
      .lastOutcome = (if $outcome == "" then null else $outcome end)' \
    --arg verdict "$verdict" \
    --arg outpath "$outpath" \
    --arg action "$action" \
    --arg outcome "$outcome" \
    --arg stage_status "$stage_status" \
    --argjson now "$now"
}

ps_set_status() {
  local wsp="$1" pid="$2" status="$3" errmsg="${4:-}"
  local now; now="$(epoch_ms)"
  local completed_jq="null"
  [ "$status" = "completed" ] && completed_jq="$now"
  ps_update "$wsp" "$pid" '
    .status = $status |
    .error = (if $errmsg == "" then null else $errmsg end) |
    .completedAt = $completed' \
    --arg status "$status" \
    --arg errmsg "$errmsg" \
    --argjson completed "$completed_jq"
}
