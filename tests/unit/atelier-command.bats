#!/usr/bin/env bats

@test "atelier.md exists and references all five branches" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  [ -f "$cf" ]
  for keyword in "new task" "resume" "restart" "status" "abort"; do
    grep -qi "$keyword" "$cf"
  done
}

@test "atelier.md references the helper scripts by name" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  for s in start-pipeline.sh resume.sh restart-stage.sh abort.sh list-topologies.sh; do
    grep -q "$s" "$cf"
  done
}

@test "atelier.md instructs the LLM to call atelier_signal" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  grep -q "atelier_signal" "$cf"
}

extract_section() {
  awk -v h="$2" 'BEGIN{p=0} $0 == "### " h {p=1; next} p && /^### / {p=0} p {print}' "$1"
}

@test "atelier.md new-task branch omits verdict" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  section="$(extract_section "$cf" "New task")"
  echo "$section" | grep -q "atelier_signal"
  # The new-task signal call's JSON argument object (between backticks) must
  # not include `verdict`. The section may discuss verdict in prose, but the
  # call itself must omit it.
  call_line="$(echo "$section" | grep "atelier_signal" | head -1)"
  call_args="$(echo "$call_line" | grep -oE '\{[^}]*\}' | head -1)"
  [ -n "$call_args" ]
  ! echo "$call_args" | grep -qE 'verdict'
}

@test "atelier.md no longer references .atelier/active-pipeline" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  ! grep -q '\.atelier/active-pipeline' "$cf"
}

@test "atelier.md status output exposes ownership (sourceSessionId / mine)" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  section="$(extract_section "$cf" "Status")"
  echo "$section" | grep -qE "sourceSessionId|mine"
}

@test "atelier.md new-task signal call includes pipelineId" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  section="$(extract_section "$cf" "New task")"
  call_line="$(echo "$section" | grep "atelier_signal" | head -1)"
  echo "$call_line" | grep -q "pipelineId"
}

@test "atelier.md explicitly forbids signaling from resume/restart branches" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  extract_section "$cf" "Resume" | grep -q "DO NOT call .*atelier_signal"
  extract_section "$cf" "Restart from stage" | grep -q "DO NOT call .*atelier_signal"
}

@test "atelier.md references AskUserQuestion for ambiguity" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  grep -q "AskUserQuestion" "$cf"
}

@test "atelier.md invokes redirect.sh with the guidance arg only (not pipeline id)" {
  cf="$BATS_TEST_DIRNAME/../../commands/atelier.md"
  # The redirect script's signature is `redirect.sh "<guidance>"`. Calling it
  # with `<id> "<guidance>"` would silently store the id as the guidance text.
  # Match: the dispatcher must invoke redirect.sh with a quoted string as the
  # first positional argument — never a bare <id>-then-quoted-string form.
  call="$(grep -oE 'scripts/redirect\.sh[^`]*' "$cf" | head -1)"
  [ -n "$call" ]
  # The call must contain a single quoted argument and nothing that looks like a pid before it.
  echo "$call" | grep -qE 'redirect\.sh +"<guidance>"'
  ! echo "$call" | grep -qE 'redirect\.sh +<id>'
}
