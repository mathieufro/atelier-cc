# Shared bats helpers.
#
# Skill fixtures: many unit tests need to substitute a fake SKILL.md into the
# plugin's real skills/<name>/ directory (because compile-prompt.sh / stop.sh
# read from there). Without care, the test would clobber synced content. Use
# backup_skill in setup and restore_skill in teardown — they preserve the
# original SKILL.md across the test and remove only test-created directories.
backup_skill() {
  local name="$1"
  local dir="$ATELIER_CC_ROOT/skills/$name"
  if [ -f "$dir/SKILL.md" ]; then
    cp "$dir/SKILL.md" "$dir/SKILL.md.bak"
  fi
  mkdir -p "$dir"
}

restore_skill() {
  local name="$1"
  local dir="$ATELIER_CC_ROOT/skills/$name"
  if [ -f "$dir/SKILL.md.bak" ]; then
    mv "$dir/SKILL.md.bak" "$dir/SKILL.md"
  else
    rm -rf "$dir"
  fi
}

# Shared bats integration helpers. Drives one routing iteration:
# 1. If no stage is in flight, Stop hook bootstraps the first dispatch.
# 2. Simulate stage work — write a stub artifact if requiresArtifact.
# 3. ps_complete_stage simulates atelier_signal verdict=done.
# 4. SubagentStop fires (autonomous mode only) — and as of the SubagentStop
#    dispatch refactor, it both records sessionId AND dispatches the next stage
#    in one go, mirroring how Claude Code hands the block reason back to the
#    main agent so the intermediate "main-agent turn" is skipped.
drive_one_iteration() {
  local wsp="$1" pid="$2"
  local sp="$wsp/.atelier/pipelines/$pid/pipeline-state.json"
  local sid="${CLAUDE_CODE_SESSION_ID:-sess-t}"

  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"

  # One iteration = one Claude Code event. Two phases mirror what the runtime
  # does between LLM turns: (A) if no stage is in flight, fire Stop to dispatch;
  # (B) otherwise simulate the stage producing its artifact and signaling, then
  # fire SubagentStop (autonomous) — which now dispatches the next stage in the
  # same call.
  local last_status last_verdict
  last_status="$(jq -r '.stages[-1].status // ""' "$sp")"
  last_verdict="$(jq -r '.lastVerdict // empty' "$sp")"
  if [ "$last_status" != "running" ] || [ -n "$last_verdict" ]; then
    printf '{"cwd":"%s","session_id":"%s"}' "$wsp" "$sid" \
      | "$ATELIER_CC_ROOT/hooks/stop.sh" >/dev/null || true
    return 0
  fi

  local stage assigned mode
  stage="$(jq -r .currentStage "$sp")"
  assigned="$(jq -r '.stages[-1].assignedOutputPath // empty' "$sp")"
  mode="$(jq -r '.expectedMode' "$sp")"

  if [ -n "$assigned" ]; then
    mkdir -p "$(dirname "$assigned")"
    echo "# Stub artifact for $stage" > "$assigned"
  fi

  ps_complete_stage "$wsp" "$pid" "done" "$assigned"

  if [ "$mode" = "autonomous" ]; then
    printf '{"agent_type":"atelier:atelier-stage-worker","agent_id":"sim","cwd":"%s","session_id":"%s"}' "$wsp" "$sid" \
      | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh" >/dev/null || true
  fi
}
