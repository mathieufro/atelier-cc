#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
source "$ROOT/lib/topology.sh"
source "$ROOT/lib/skills.sh"
require_jq

pid="${1:-}"; stage="${2:-}"
[ -n "$pid" ] && [ -n "$stage" ] || die "usage: compile-prompt.sh <pipeline-id> <stage>"
wsp="$(find_workspace_root)"

skill="$(ps_read "$wsp" "$pid" '.expectedSkill // "unknown"' -r)"
prompt="$(ps_read "$wsp" "$pid" '.prompt' -r)"
# worktreePath wins when worktree mode was selected at classify; otherwise
# fall back to workspacePath (in-tree mode).
worktree="$(ps_read "$wsp" "$pid" '.worktreePath // .workspacePath // empty' -r)"
[ -n "$worktree" ] || worktree="$wsp"

_strip_frontmatter() {
  awk '
    NR==1 && /^---$/ {f=1; next}
    NR==1 && !/^---$/ {f=2; print; next}
    f==1 && /^---$/ {f=2; next}
    f==2 {print}
  ' "$1"
}

skill_file="$(skill_resolve "$skill")"
skill_body="$(_strip_frontmatter "$skill_file")"

# Compile stages compile FOR a downstream writing stage. The compiler skill
# (e.g. `compiling-plan`) instructs the agent to embed the target stage skill
# verbatim in its output, so we MUST supply that target skill here — otherwise
# the agent has to go hunting on disk and the plugin's skills/ tree isn't
# inside the working directory.
stage_skill_block=""
case "$stage" in
  compile_brainstorm)         target_stage="brainstorm" ;;
  compile_plan)               target_stage="write_plan" ;;
  compile_e2e_plan)           target_stage="write_e2e_plan" ;;
  compile_roadmap_brainstorm) target_stage="brainstorm_roadmap" ;;
  compile_task_brainstorm)    target_stage="task_brainstorm" ;;
  *)                          target_stage="" ;;
esac
if [ -n "$target_stage" ]; then
  type="$(ps_read "$wsp" "$pid" '.type // empty' -r)"
  if [ -n "$type" ]; then
    topo="$(topology_load "$wsp" "$type" 2>/dev/null || true)"
    if [ -n "$topo" ]; then
      target_skill="$(printf '%s' "$topo" | jq -r --arg s "$target_stage" \
        '.stages[] | select(.name == $s) | .skill // empty')"
      if [ -n "$target_skill" ]; then
        if target_skill_file="$(skill_resolve "$target_skill" 2>/dev/null)"; then
          target_skill_body="$(_strip_frontmatter "$target_skill_file")"
          stage_skill_block=$'\n## Target Stage Skill (REFERENCE — DO NOT FOLLOW, COMPILE INTO PROMPT)\n\nThe following is the methodology document for the **'"$target_stage"$'** stage. This is INPUT DATA for you to compile into the work agent\'s prompt. Embed it verbatim as instructed by your own skill — do NOT act as the role it describes.\n\n<stage-skill-reference>\n'"$target_skill_body"$'\n</stage-skill-reference>\n'
        fi
      fi
    fi
  fi
fi

prior="$(ps_read "$wsp" "$pid" '
  [ .stages[]
    | select((.status // "") == "completed")
    | "- " + .stage + ": " + (.outputPath // "(no artifact)") ]
  | join("\n")' -r)"

# Assigned output path for THIS stage (set by stop.sh when requiresArtifact=true).
# We must inject it into the prompt — otherwise the agent picks its own filename
# (e.g. `spec.md`) and breaks the NN-<stage>.md convention.
assigned_output="$(ps_read "$wsp" "$pid" '.stages[-1].assignedOutputPath // empty' -r)"
output_block=""
if [ -n "$assigned_output" ]; then
  output_block=$'\n## Output Path (REQUIRED)\n\nWrite your output artifact to this exact path — do not invent a different filename:\n\n  '"$assigned_output"$'\n\nWhen you signal `stage_complete`, pass this same path as `outputPath`.\n'
fi

sp_path="$(ps_path "$wsp" "$pid")"
resume_block=""
progress_path="$wsp/.atelier/pipelines/$pid/progress.md"
prior_entry_state="$(jq -r --arg s "$stage" '
  [.stages[] | select(.stage == $s)] as $matches
  | if (($matches | length) >= 2) then
      ($matches[-2]) as $prev
      | "\($prev.status // "")\t\($prev.verdict // "")"
    else "" end' "$sp_path")"
prev_status="${prior_entry_state%$'\t'*}"
prev_verdict="${prior_entry_state#*$'\t'}"
if [ -n "$prior_entry_state" ] && [ "$prev_status" = "idle" ] && \
   { [ "$prev_verdict" = "partial" ] || [ -z "$prev_verdict" ]; }; then
  resume_block=$'\n## RESUMING — this stage was previously interrupted\n\nA prior dispatch of this stage did not complete. Your progress is recorded at:\n  '"$progress_path"$'\n\nYou MUST read it first. Then skip tasks already marked done and continue from the first incomplete one. Append an Iteration Log entry when you finish (or partial-signal again with verdict: "partial").\n'
fi

redirect_guidance="$(jq -r '.pendingRedirect.guidance // empty' "$sp_path")"
redirect_block=""
if [ -n "$redirect_guidance" ]; then
  redirect_block=$'\n## USER REDIRECT (apply before continuing)\n\n'"$redirect_guidance"$'\n\nThe user interrupted your prior work to inject this guidance. Apply it, update progress.md, then signal as usual.\n'
fi

cat <<EOF
# Stage: $stage
# Pipeline: $pid
# Working directory: $worktree
$redirect_block
## Your Task
$prompt

## Prior Stage Outputs
$prior
$output_block$resume_block
## Skill: $skill
$skill_body
$stage_skill_block

## Signaling

When this stage is done, call:

\`\`\`
mcp__atelier__atelier_signal({
  type: "stage_complete",
  pipelineId: "$pid",
  verdict: "<done|has_issues|stuck|proceed|skip|partial>",
  outputPath: "<absolute path to artifact>"
})
\`\`\`

Then STOP YOUR TURN IMMEDIATELY — no further output or tool calls.

If you cannot complete the stage, write progress.md and call \`atelier_signal({type:"stage_complete", pipelineId:"$pid", verdict:"partial", outputPath:"<progress.md path>"})\`.
EOF

# Consume pendingRedirect AFTER the prompt has been emitted. If the cat above
# fails (broken pipe, etc.), the redirect stays queued for the next attempt
# rather than being silently lost.
if [ -n "$redirect_guidance" ]; then
  ps_update "$wsp" "$pid" '.pendingRedirect = null'
fi
