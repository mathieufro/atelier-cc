#!/usr/bin/env bats

@test "agent file exists with required frontmatter" {
  agent="$BATS_TEST_DIRNAME/../../agents/atelier-stage-worker.md"
  [ -f "$agent" ]
  head -1 "$agent" | grep -q '^---$'
  grep -q '^name: atelier-stage-worker$' "$agent"
}

@test "agent system prompt mentions atelier_signal and ending the turn (not the self-defeating 'no output')" {
  agent="$BATS_TEST_DIRNAME/../../agents/atelier-stage-worker.md"
  grep -q 'atelier_signal' "$agent"
  grep -q -i 'end your turn' "$agent"
  # The old wording forbade ALL output, leaving a subagent no way to emit the
  # final message that closes its turn — it looped and the pipeline wedged.
  ! grep -q -i 'no further output' "$agent"
}

@test "agent inherits parent session tool allowlist (no tools: field)" {
  agent="$BATS_TEST_DIRNAME/../../agents/atelier-stage-worker.md"
  # Several skills (validating, bugfixing, e2e-validation, ...) need tools beyond
  # the standard set (mcp__strobe__*, Skill, BashOutput). Omitting the `tools:`
  # field makes the worker inherit the parent allowlist; an explicit list would
  # silently strip the long tail.
  ! grep -q '^tools:$' "$agent"
  ! grep -qE '^[[:space:]]+- mcp__atelier__atelier_signal' "$agent"
}
