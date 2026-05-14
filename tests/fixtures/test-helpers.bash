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
# 1. Stop hook to dispatch.
# 2. Simulate stage work — write a stub artifact if requiresArtifact.
# 3. Call ps_complete_stage to simulate atelier_signal verdict=done.
# 4. SubagentStop (autonomous mode only).
drive_one_iteration() {
  local wsp="$1" pid="$2"
  local sp="$wsp/.atelier/pipelines/$pid/pipeline-state.json"
  local sid="${CLAUDE_SESSION_ID:-sess-t}"

  local decision
  decision="$(printf '{"cwd":"%s","session_id":"%s"}' "$wsp" "$sid" | "$ATELIER_CC_ROOT/hooks/stop.sh" || true)"

  [ -z "$decision" ] && return 0

  local stage assigned mode
  stage="$(jq -r .currentStage "$sp")"
  assigned="$(jq -r '.stages[-1].assignedOutputPath // empty' "$sp")"
  mode="$(jq -r '.expectedMode' "$sp")"

  if [ -n "$assigned" ]; then
    mkdir -p "$(dirname "$assigned")"
    echo "# Stub artifact for $stage" > "$assigned"
  fi

  source "$ATELIER_CC_ROOT/lib/common.sh"
  source "$ATELIER_CC_ROOT/lib/pipeline-state.sh"
  ps_complete_stage "$wsp" "$pid" "done" "$assigned"

  if [ "$mode" = "autonomous" ]; then
    printf '{"agent_type":"atelier:atelier-stage-worker","agent_id":"sim","cwd":"%s","session_id":"%s"}' "$wsp" "$sid" \
      | "$ATELIER_CC_ROOT/hooks/subagent-stop.sh"
  fi
}
