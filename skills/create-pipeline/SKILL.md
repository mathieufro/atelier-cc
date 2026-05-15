---
name: create-pipeline
description: Guided interactive skill for authoring custom Atelier pipelines (topology + skills + README) and emitting a self-installing bash script
---

# Create Custom Pipeline

You guide the user through designing their own Atelier pipeline and produce a self-installing bash script that drops the topology, skill files, and README into `$HOME/.atelier/`.

## Input Format

The user provides a pipeline specification roughly like:

```
Pipeline name: <kebab-case name>
Description: <one-line summary of what the pipeline does>

Stages:
1. <stage-name> (interactive|autonomous): <what this stage does>
2. <stage-name> (interactive|autonomous): <what this stage does>
... (3-8 stages typical)
```

If the user input is missing or vague, ask follow-up questions before producing the script. Do NOT invent a pipeline they didn't describe.

## Your Task

1. **Validate the spec** —
   - Pipeline name is non-empty kebab-case.
   - Description is present.
   - Between 2 and 8 stages.
   - Each stage has a valid mode (`interactive` or `autonomous`).
   - Stage descriptions are specific (not vague placeholders).
   - If anything is off, ask the user to fix it before proceeding.

2. **Synthesize each skill** — for each stage, write a complete `SKILL.md`:
   - Frontmatter: `name`, `description`.
   - Body: 30-100 lines of concrete agent instructions for that stage.
   - Use domain-specific language from the user's spec — don't write generic placeholder skills.

3. **Create the topology** — a JSON object with the pipeline's stages, modes, and artifact types:
   - `artifactType` per stage (e.g. `"invoices"`, `"ledger"`, `"report"`).
   - Interactive stages set `requiresArtifact: true`.
   - Autonomous stages can chain for progressive refinement.

4. **Write the README** — a short user-facing guide (≤200 words) covering:
   - What the pipeline does.
   - Which stages are interactive vs. autonomous.
   - Example invocation: `/atelier "your task here"` then pick this pipeline.

5. **Emit a self-installing bash script** — write a single executable bash file to the assigned output path. When the user runs `bash <script> --install`, it must:
   - Create `$HOME/.atelier/topologies/<name>.json`.
   - Create `$HOME/.atelier/skills/<stage>/SKILL.md` for every stage.
   - Optionally write the README to `$HOME/.<pipeline-name>-readme.md`.
   - Be idempotent — re-running prints warnings for existing files but never corrupts them.
   - Print one success line per file written.
   - Exit 0 on success, non-zero on error.

## Output

Write the complete bash install script to the path given in `## Output Path (REQUIRED)`. When you signal `stage_complete`, pass that same path as `outputPath`. Tell the user how to run it:

    bash <path> --install

## Constraints

- The bash script must be syntactically valid (`bash -n <script>` clean).
- The topology must parse as valid JSON.
- All file names use only alphanumerics, hyphens, underscores — no spaces, no `../` escapes.
- Each SKILL.md must be a standalone, actionable instruction document, not a stub.
- Do NOT install anything yourself — only emit the script. The user runs it.
