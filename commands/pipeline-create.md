---
description: Guided interactive authoring of a custom Atelier pipeline — emits a self-installing bash script that drops topology + skills into $HOME/.atelier/
argument-hint: <optional initial pipeline description>
---

You are launching the `create-pipeline` interactive skill. `$ARGUMENTS` may contain the user's initial pipeline sketch.

## Step 1 — Start a pipeline

Run `Bash`: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/start-pipeline.sh "create custom pipeline: $ARGUMENTS"` — capture the pipeline id.

## Step 2 — Configure the classify gate

The create-pipeline pipeline is a single interactive stage. There is no plugin topology named `create-pipeline` by default, so the user must have either:

- Authored `<workspace>/.atelier/topologies/create-pipeline.json` themselves, OR
- Run this command after installing it via a prior bootstrap

If `bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-topologies.sh | grep -q '^create-pipeline\t'` returns non-zero, fall back: write a one-stage `create-pipeline` topology into `<workspace>/.atelier/topologies/create-pipeline.json` containing:

```json
{
  "name": "create-pipeline",
  "description": "Author a custom Atelier pipeline interactively",
  "stages": [
    { "name": "create_pipeline", "mode": "interactive", "skill": "create-pipeline", "artifactType": "pipeline", "requiresArtifact": true }
  ]
}
```

## Step 3 — Signal classify

Call `mcp__atelier__atelier_signal` with `{type:"stage_complete", pipelineId:"<id>", pipelineType:"create-pipeline", worktreeChoice:"in-tree"}`. **No `verdict`.** STOP YOUR TURN.

The Stop hook then dispatches the `create_pipeline` interactive stage, which loads the `create-pipeline` skill (from `$HOME/.atelier/skills/create-pipeline/SKILL.md` if the user customized it, else from the plugin). The skill walks the user through the design and emits a self-installing bash script to the pipeline's assigned output path. The user then runs:

    bash <output-path> --install

to drop the topology and skill files into `$HOME/.atelier/`.
