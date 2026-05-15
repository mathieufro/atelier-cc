#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  WSP="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
}

teardown() {
  rm -rf "$WSP" "$FAKE_HOME"
}

@test "create-pipeline skill compiles into a prompt with author guidance" {
  pid="create-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{
  "id": "$pid",
  "type": "create-pipeline",
  "status": "running",
  "prompt": "Pipeline name: invoice-flow\nDescription: Process vendor invoices into accounting\n\nStages:\n1. receive-invoices (interactive): User uploads invoices\n2. extract-data (autonomous): Parse invoice PDFs\n3. validate (autonomous): Sanity-check extracted data",
  "expectedSkill": "create-pipeline",
  "workspacePath": "$WSP",
  "stages": [{
    "id": "s1",
    "stage": "create_pipeline",
    "status": "running",
    "assignedOutputPath": "$WSP/.atelier/pipelines/$pid/01-invoice-flow-pipeline.sh"
  }]
}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "create_pipeline"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pipeline name"* ]]
  [[ "$output" == *"stages"* || "$output" == *"Stages"* ]]
  [[ "$output" == *"install"* ]]
}

@test "create-pipeline skill file exists and has valid frontmatter" {
  skill="$ATELIER_CC_ROOT/skills/create-pipeline/SKILL.md"
  [ -f "$skill" ]
  head -1 "$skill" | grep -q '^---$'
  grep -q '^name: create-pipeline$' "$skill"
  grep -q '^description: ' "$skill"
}
