#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  source "$BATS_TEST_DIRNAME/../../lib/routing.sh"
}

TOPOLOGY='{
  "name":"feature",
  "stages":[
    {"name":"brainstorm","mode":"interactive","skill":"brainstorming-feature","requiresArtifact":true},
    {"name":"review_spec","mode":"autonomous","skill":"reviewing-specs","reviewBehavior":"fixing-specs","requiresArtifact":true},
    {"name":"write_plan","mode":"autonomous","skill":"writing-plans","requiresArtifact":true},
    {"name":"review_plan","mode":"autonomous","skill":"reviewing-plans","reviewBehavior":"fixing","requiresArtifact":true},
    {"name":"implement","mode":"autonomous","skill":"implementing-plans","supportsPartial":true},
    {"name":"e2e_gate","mode":"autonomous","skill":"e2e-gating","gateBehavior":"skip-to-validate","requiresArtifact":true},
    {"name":"e2e","mode":"autonomous","skill":"e2e-validation","supportsPartial":true},
    {"name":"validate","mode":"autonomous","skill":"validating"}
  ]
}'

@test "no currentStage: dispatch first stage" {
  state='{"currentStage":null,"lastVerdict":null,"fixAttempts":{}}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "brainstorm" ]
}

@test "verdict=done advances to next stage" {
  state='{"currentStage":"brainstorm","lastVerdict":"done","fixAttempts":{},"stages":[{"id":"s1","stage":"brainstorm","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .stage.name)" = "review_spec" ]
}

@test "verdict=done on last stage terminates with completed" {
  state='{"currentStage":"validate","lastVerdict":"done","fixAttempts":{},"stages":[{"id":"s1","stage":"validate","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "terminate" ]
  [ "$(echo "$result" | jq -r .newStatus)" = "completed" ]
}

@test "verdict=has_issues on review stage inserts fix stage" {
  state='{"currentStage":"review_spec","lastVerdict":"has_issues","fixAttempts":{},"stages":[{"id":"rs1","stage":"review_spec","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "fix_spec" ]
  [ "$(echo "$result" | jq -r .stage.skill)" = "fixing-specs" ]
  [ "$(echo "$result" | jq -r .stage.supportsPartial)" = "true" ]
  [ "$(echo "$result" | jq -r .isFixStage)" = "true" ]
  [ "$(echo "$result" | jq -r .parentReviewStageId)" = "rs1" ]
  [ "$(echo "$result" | jq -r .incrementFixAttempts)" = "review_spec" ]
}

@test "verdict=done on fix stage advances past parent review (no re-review)" {
  state='{"currentStage":"fix_spec","lastVerdict":"done","fixAttempts":{"rs1":1},"stages":[{"id":"rs1","stage":"review_spec","status":"completed"},{"id":"fs1","stage":"fix_spec","status":"completed","dynamicallyInserted":true,"parentReviewStageId":"rs1"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "write_plan" ]
}

@test "verdict=has_issues at fix attempt cap pauses pipeline" {
  state='{"currentStage":"review_spec","lastVerdict":"has_issues","fixAttempts":{"review_spec":5},"stages":[{"id":"rs1","stage":"review_spec","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "pause" ]
  [ "$(echo "$result" | jq -r .newStatus)" = "idle" ]
  [[ "$(echo "$result" | jq -r .error)" == *"fix attempt cap"* ]]
}

@test "fixAttempts cap survives review re-entry (keyed by name not id)" {
  state='{"currentStage":"review_spec","lastVerdict":"has_issues","fixAttempts":{"review_spec":4},"stages":[{"id":"rs1","stage":"review_spec","status":"completed"},{"id":"f1","stage":"fix_spec","status":"completed","dynamicallyInserted":true,"parentReviewStageId":"rs1"},{"id":"rs2","stage":"review_spec","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .incrementFixAttempts)" = "review_spec" ]
}

@test "verdict=partial on partial-supporting stage re-dispatches same" {
  state='{"currentStage":"implement","lastVerdict":"partial","fixAttempts":{"implement":2},"stages":[{"id":"i1","stage":"implement","status":"idle"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "implement" ]
}

@test "verdict=partial dispatch sets incrementFixAttempts (regression: cap unreachable)" {
  # Positional arg bug previously put $current in the parent_id slot and left
  # inc_attempts empty, so fixAttempts never incremented and the partial retry
  # cap was unreachable — a deterministically-partial stage would loop forever.
  state='{"currentStage":"implement","lastVerdict":"partial","fixAttempts":{"implement":2},"stages":[{"id":"i1","stage":"implement","status":"idle"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .incrementFixAttempts)" = "implement" ]
  [ "$(echo "$result" | jq -r .parentReviewStageId)" = "null" ]
  [ "$(echo "$result" | jq -r .isFixStage)" = "false" ]
}

@test "verdict=partial at retry cap (5) pauses" {
  state='{"currentStage":"implement","lastVerdict":"partial","fixAttempts":{"implement":5},"stages":[{"id":"i1","stage":"implement","status":"idle"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "pause" ]
  [[ "$(echo "$result" | jq -r .error)" == *"partial retry cap"* ]]
}

@test "verdict=skip on e2e_gate jumps to validate" {
  state='{"currentStage":"e2e_gate","lastVerdict":"skip","fixAttempts":{},"stages":[{"id":"g1","stage":"e2e_gate","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .stage.name)" = "validate" ]
}

@test "verdict=proceed on e2e_gate advances normally" {
  state='{"currentStage":"e2e_gate","lastVerdict":"proceed","fixAttempts":{},"stages":[{"id":"g1","stage":"e2e_gate","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .stage.name)" = "e2e" ]
}

@test "verdict=stuck pauses pipeline" {
  state='{"currentStage":"implement","lastVerdict":"stuck","fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "pause" ]
  [ "$(echo "$result" | jq -r .newStatus)" = "idle" ]
}

@test "verdict=has_issues on non-review stage advances normally" {
  state='{"currentStage":"implement","lastVerdict":"has_issues","fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"completed"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .stage.name)" = "e2e_gate" ]
}

@test "verdict=null with stage status=idle: re-dispatch (crash-recovery path)" {
  state='{"currentStage":"implement","lastVerdict":null,"fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"idle"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "implement" ]
}

@test "verdict=null with stage status=running: pause stuck (subagent died without signaling)" {
  state='{"currentStage":"implement","lastVerdict":null,"fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"running"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "pause" ]
  [ "$(echo "$result" | jq -r .newStatus)" = "stuck" ]
  [[ "$(echo "$result" | jq -r .error)" == *"without signaling"* ]]
}

# Recovery paths: any non-running terminal status with verdict=null means someone
# cleared the verdict to ask for a fresh dispatch (restart-stage, resume after
# subagent-stop, manual repair). Routing must self-recover, not wedge.

@test "verdict=null with stage status=completed: re-dispatch fresh (restart-stage path)" {
  state='{"currentStage":"implement","lastVerdict":null,"fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"completed","verdict":"done"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "implement" ]
}

@test "verdict=null with stage status=skipped: re-dispatch fresh" {
  state='{"currentStage":"implement","lastVerdict":null,"fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"skipped","interrupted":true}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "implement" ]
}

@test "verdict=null on a dynamically-inserted fix stage with status=idle: re-dispatch synthesized fix stage (regression: produced a stage row literally named \"null\")" {
  # When a fix_* subagent crashes and resume demotes status stuck->idle, the
  # Stop hook re-enters with currentStage=fix_X. fix_* isn't in the topology,
  # so $stage is empty — previously this flowed into _routing_emit and we
  # appended a stage row whose .stage was the string "null". Now routing must
  # synthesize the fix-stage JSON the same way the has_issues branch does.
  state='{"currentStage":"fix_spec","lastVerdict":null,"fixAttempts":{"review_spec":1},"stages":[{"id":"rs1","stage":"review_spec","status":"completed","verdict":"has_issues"},{"id":"fs1","stage":"fix_spec","status":"idle","dynamicallyInserted":true,"parentReviewStageId":"rs1","error":"subagent terminated without signaling"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "dispatch" ]
  [ "$(echo "$result" | jq -r .stage.name)" = "fix_spec" ]
  [ "$(echo "$result" | jq -r .stage.mode)" = "autonomous" ]
  [ "$(echo "$result" | jq -r .stage.skill)" != "" ]
  [ "$(echo "$result" | jq -r .stage.skill)" != "null" ]
  [ "$(echo "$result" | jq -r .isFixStage)" = "true" ]
  [ "$(echo "$result" | jq -r .parentReviewStageId)" = "rs1" ]
}

@test "verdict=null with stage status=stuck: pause (don't auto-retry crashed subagent)" {
  # Stuck on the last stage row means subagent-stop.sh already recorded a crash.
  # Auto-redispatching here would loop forever on a deterministically-crashing
  # subagent. resume.sh demotes stuck → idle to opt back into dispatch.
  state='{"currentStage":"implement","lastVerdict":null,"fixAttempts":{},"stages":[{"id":"i1","stage":"implement","status":"stuck","error":"subagent terminated without signaling"}]}'
  result="$(routing_decide "$state" "$TOPOLOGY")"
  [ "$(echo "$result" | jq -r .kind)" = "pause" ]
  [ "$(echo "$result" | jq -r .newStatus)" = "stuck" ]
  [[ "$(echo "$result" | jq -r .error)" == *"without signaling"* ]]
}
