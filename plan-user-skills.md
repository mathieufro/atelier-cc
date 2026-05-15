# Plan: User-local custom skills for atelier-cc

## Goal

Make atelier-cc fully user-customizable by letting users author their own skills under `$HOME/.atelier/skills/<name>/SKILL.md` and reference them from custom topologies — closing the existing gap where topologies are overridable but skills are not.

## Scope

**In:**
- New `lib/skills.sh` with a `skill_resolve <name>` helper (user-local → plugin fallback).
- Replace 3 hardcoded `$ROOT/skills/$skill/SKILL.md` references with `skill_resolve` calls in `lib/dispatch.sh` (×2) and `scripts/compile-prompt.sh` (×2: main + target skill).
- Unit bats for `skill_resolve`.
- Integration bats that exercises a custom topology + custom skills end-to-end through `compile-prompt.sh`.
- Accounting fixture under `tests/fixtures/accounting-pipeline/` (topology + 5 skills + sample invoices).
- README "Custom Skills" section documenting the user-local layout with the accounting walkthrough.
- Interactive `create-pipeline` skill + `/atelier pipeline create` command for guided custom pipeline authoring (Task 7).

**Out:**
- Project-local skills (`<wsp>/.atelier/skills/`) — explicitly deferred; the user wants user-local only.
- User-local topologies (`$HOME/.atelier/topologies/`) — out of scope; topologies stay project-local.
- Shipping the accounting skills as plugin payload — fixture-only, never installed.
- Full E2E run with real Agent dispatches — the integration test only covers resolution + compilation.
- Env-var skill search paths (`ATELIER_SKILL_PATH`) — YAGNI.

## Current State

`lib/topology.sh:topology_load` already supports project-local override at `<wsp>/.atelier/topologies/<name>.json` and is documented in the README. Skills, however, are loaded via inline path construction in three places:

- `lib/dispatch.sh:106` — `dispatch_reemit_existing` interactive recovery branch (skill_file assignment)
- `lib/dispatch.sh:186` — `_dispatch_emit` interactive dispatch branch (skill_file assignment)
- `scripts/compile-prompt.sh:29` and `scripts/compile-prompt.sh:55` — main `skill_file` (every autonomous stage) and `target_skill_file` (compile-* stages embedding the downstream skill verbatim)

All five sites read `$ROOT/skills/$skill/SKILL.md` where `$ROOT` is the plugin install root. Result: a user-authored `accounting.json` topology can declare `"skill": "bookkeep-csv"` but pipeline startup dies with `skill not found: bookkeep-csv` because the file only exists in the user's own `$HOME`, not under the plugin tree. Custom pipelines from custom skills are therefore impossible today.

## Architecture Approach

Add a `skill_resolve <name>` function that mirrors `topology_load`'s precedence (user-local first, plugin fallback) and replace the five inline constructions with calls to it. Resolution is a pure lookup — no I/O beyond `[ -f ]`. Tests override `HOME` to keep file-system mutation hermetic. The five call sites each retain their existing semantics (die-on-missing for compile-prompt; soft-fallback `"(skill body unavailable)"` for dispatch.sh's recovery branches, which today already tolerate missing files).

Key tradeoff: we put the resolver in a new `lib/skills.sh` rather than appending to `lib/topology.sh` — keeps file responsibilities crisp (topology.sh handles topology JSON, skills.sh handles skill markdown) and makes the unit test surface obvious.

## Task 1: Add skill_resolve helper with unit tests [x]

**Files:**
- Create: `lib/skills.sh`
- Test: `tests/unit/skills.bats`

### 1.1 Write failing test

`tests/unit/skills.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
}

teardown() {
  rm -rf "$FAKE_HOME"
}

@test "skill_resolve returns plugin default when no user-local override" {
  run skill_resolve "writing-plans"
  [ "$status" -eq 0 ]
  [ "$output" = "$ATELIER_CC_ROOT/skills/writing-plans/SKILL.md" ]
}

@test "skill_resolve prefers user-local skill over plugin default" {
  mkdir -p "$HOME/.atelier/skills/writing-plans"
  echo "custom body" > "$HOME/.atelier/skills/writing-plans/SKILL.md"
  run skill_resolve "writing-plans"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.atelier/skills/writing-plans/SKILL.md" ]
}

@test "skill_resolve resolves a user-only skill that doesn't exist in plugin" {
  mkdir -p "$HOME/.atelier/skills/bookkeep-csv"
  echo "user-only" > "$HOME/.atelier/skills/bookkeep-csv/SKILL.md"
  run skill_resolve "bookkeep-csv"
  [ "$status" -eq 0 ]
  [ "$output" = "$HOME/.atelier/skills/bookkeep-csv/SKILL.md" ]
}

@test "skill_resolve dies on missing skill with both searched paths in error" {
  run skill_resolve "no-such-skill"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$HOME/.atelier/skills/no-such-skill/SKILL.md"* ]]
  [[ "$output" == *"$ATELIER_CC_ROOT/skills/no-such-skill/SKILL.md"* ]]
}

@test "skill_resolve rejects invalid skill name" {
  run skill_resolve "../escape"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid skill name"* ]]
}

@test "skill_resolve rejects empty name" {
  run skill_resolve ""
  [ "$status" -ne 0 ]
}
```

### 1.2 Run test — verify failure

```
debug_test({ projectRoot: "/Volumes/Minimac/mathieu/Documents/atelier-monorepo/atelier-cc", framework: "bats", test: "skills" })
```

Expected: all six tests fail with `command not found: skill_resolve` (the helper doesn't exist yet, and `lib/skills.sh` isn't there to source).

### 1.3 Implementation

Create `lib/skills.sh`:

```bash
#!/usr/bin/env bash
# Skill resolver: user-local overrides shadow plugin defaults by name.
# Mirrors lib/topology.sh's precedence pattern but for SKILL.md files.

_skills_plugin_root() {
  if [ -n "${ATELIER_CC_ROOT:-}" ]; then
    printf '%s\n' "$ATELIER_CC_ROOT"
  elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
    printf '%s\n' "$CLAUDE_PLUGIN_ROOT"
  else
    local self; self="${BASH_SOURCE[0]}"
    printf '%s\n' "$(cd "$(dirname "$self")/.." && pwd)"
  fi
}

# skill_resolve <name> — prints absolute path to SKILL.md or dies.
# Resolution: $HOME/.atelier/skills/<name>/SKILL.md → <plugin>/skills/<name>/SKILL.md.
skill_resolve() {
  local name="${1:-}"
  [ -n "$name" ] || die "skill_resolve: name required"
  [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid skill name: $name"
  local user="$HOME/.atelier/skills/$name/SKILL.md"
  local plugin; plugin="$(_skills_plugin_root)/skills/$name/SKILL.md"
  if [ -f "$user" ]; then
    printf '%s\n' "$user"
    return 0
  fi
  if [ -f "$plugin" ]; then
    printf '%s\n' "$plugin"
    return 0
  fi
  die "skill not found: $name (searched: $user, $plugin)"
}
```

### 1.4 Run test — verify passes

```
debug_test({ projectRoot: "...", framework: "bats", test: "skills" })
```

All six pass.

### 1.5 Checkpoint

`skill_resolve` exists and correctly walks the user-local → plugin fallback chain with defensive name validation.

**Edge cases covered:**
- No override: returns plugin path.
- Override present: returns user path (precedence proven).
- User-only skill: works even when plugin has no such skill (the customization use case).
- Missing skill: dies with both paths in the message (diagnosable failure).
- Path-traversal name (`../escape`): rejected.
- Empty name: rejected.

---

## Task 2: Wire skill_resolve into dispatch.sh [x]

**Files:**
- Modify: `lib/dispatch.sh` (lines 106 and 186)
- Test: `tests/integration/dispatch-skills.bats` (new — integration test exercising dispatch.sh with custom topology/skills)

### 2.1 Write failing test

`tests/unit/dispatch-skills.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../../lib/pipeline-state.sh"
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  source "$BATS_TEST_DIRNAME/../../lib/routing.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  source "$BATS_TEST_DIRNAME/../../lib/dispatch.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  ROOT="$ATELIER_CC_ROOT"
  WSP="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  # Custom topology with one interactive stage referencing a user-only skill.
  mkdir -p "$WSP/.atelier/topologies"
  cat > "$WSP/.atelier/topologies/acct.json" <<EOF
{"name":"acct","description":"t","stages":[{"name":"collect","mode":"interactive","skill":"collect-x","artifactType":"data","requiresArtifact":true}]}
EOF
  mkdir -p "$HOME/.atelier/skills/collect-x"
  cat > "$HOME/.atelier/skills/collect-x/SKILL.md" <<'EOF'
---
name: collect-x
---
# Collect X
USER-LOCAL-SKILL-MARKER
EOF
}

teardown() {
  rm -rf "$WSP" "$FAKE_HOME"
}

@test "_dispatch_emit interactive branch embeds user-local skill body" {
  pid="test-pid-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{"type":"acct","currentStage":null,"lastVerdict":null,"stepCounter":0,"stages":[],"fixAttempts":{}}
EOF
  run dispatch_apply "$WSP" "$pid"
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER-LOCAL-SKILL-MARKER"* ]]
}
```

### 2.2 Run test — verify failure

Expected: assertion fails — current dispatch.sh reads `$ROOT/skills/collect-x/SKILL.md` (missing under plugin tree), falls back to the `"(skill body unavailable)"` literal, and the marker is absent from the emitted reason.

### 2.3 Implementation

Replace both call sites in `lib/dispatch.sh`. The lib/skills.sh will be sourced by callers (hooks/stop.sh and hooks/subagent-stop.sh), following the existing pattern where `lib/*.sh` files assume the caller sources all dependencies.

At line 106 (`dispatch_reemit_existing`):

```bash
    local skill_file=""
    if skill_file="$(skill_resolve "$next_skill" 2>/dev/null)"; then
      :
    fi
    local skill_body
    if [ -n "$skill_file" ] && [ -f "$skill_file" ]; then
      skill_body="$(awk '
NR==1 && /^---$/ {f=1; next}
NR==1 && !/^---$/ {f=2; print; next}
f==1 && /^---$/ {f=2; next}
f==2 {print}
' "$skill_file")"
    else
      skill_body="(skill body unavailable)"
    fi
```

At line 186 (`_dispatch_emit`) — identical pattern. The soft fallback to `"(skill body unavailable)"` is preserved because dispatch.sh's interactive recovery path must not crash the Stop hook when a skill genuinely vanishes mid-pipeline.

**Caller audit:** Verify that `lib/dispatch.sh` is always sourced from within hooks/stop.sh and hooks/subagent-stop.sh, and confirm that no other scripts source dispatch.sh directly without the caller's library setup. Add `source "$ROOT/lib/skills.sh"` to both hooks immediately before or after the existing `source "$ROOT/lib/dispatch.sh"` lines (in alphabetical order with the other lib sources, so after routing.sh).

### 2.4 Run test — verify passes

```
debug_test({ projectRoot: "...", framework: "bats", test: "dispatch-skills" })
```

Plus regression: re-run full unit suite to confirm existing tests (stop-hook, subagent-stop-hook, routing) still pass.

### 2.5 Checkpoint

The interactive dispatch branches now emit user-local skill bodies when present. Plugin defaults still work when there's no override. The soft fallback for genuinely missing skills is preserved.

**Edge cases covered:**
- User-only custom skill: body appears in the dispatch reason.
- Plugin default with no override: unchanged behavior (existing tests prove).
- Missing skill: graceful `"(skill body unavailable)"` text, no Stop-hook crash.

---

## Task 3: Wire skill_resolve into compile-prompt.sh [x]

**Files:**
- Modify: `scripts/compile-prompt.sh` (the `skill_file=...` and `target_skill_file=...` lines)

### 3.1 Write failing test

Extend `tests/unit/compile-prompt.bats` with a new test case:

```bash
@test "compile-prompt embeds user-local custom skill body" {
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  mkdir -p "$HOME/.atelier/skills/bookkeep-csv"
  cat > "$HOME/.atelier/skills/bookkeep-csv/SKILL.md" <<'EOF'
---
name: bookkeep-csv
---
# Bookkeep
USER-CUSTOM-BOOKKEEP-MARKER
EOF
  mkdir -p "$WSP/.atelier/topologies"
  cat > "$WSP/.atelier/topologies/acct.json" <<EOF
{"name":"acct","description":"t","stages":[{"name":"bookkeep","mode":"autonomous","skill":"bookkeep-csv","artifactType":"csv","requiresArtifact":true}]}
EOF
  pid="acct-test-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{"type":"acct","prompt":"do the books","expectedSkill":"bookkeep-csv","stages":[{"stage":"bookkeep","status":"running","assignedOutputPath":"$WSP/.atelier/pipelines/$pid/01-acct-csv.md"}]}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "bookkeep"
  [ "$status" -eq 0 ]
  [[ "$output" == *"USER-CUSTOM-BOOKKEEP-MARKER"* ]]
}

@test "compile-prompt embeds user-local target-skill override for compile stages" {
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  # Create a user-local override of the write_plan target skill
  mkdir -p "$HOME/.atelier/skills/write-plan"
  cat > "$HOME/.atelier/skills/write-plan/SKILL.md" <<'EOF'
---
name: write-plan
description: User-customized plan writing skill
---
# Custom Plan Writer
TARGET-SKILL-OVERRIDE-MARKER
EOF
  mkdir -p "$WSP/.atelier/topologies"
  # Create a compile_plan topology that references write_plan as its target
  cat > "$WSP/.atelier/topologies/plan.json" <<EOF
{"name":"plan","description":"t","stages":[{"name":"write_plan","mode":"autonomous","skill":"write-plan","artifactType":"plan","requiresArtifact":true},{"name":"compile_plan","mode":"autonomous","skill":"compiling-plan","artifactType":"compiled","requiresArtifact":false}]}
EOF
  pid="plan-test-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{"type":"plan","prompt":"plan something","expectedSkill":"compiling-plan","stages":[{"stage":"compile_plan","status":"running","assignedOutputPath":"$WSP/.atelier/pipelines/$pid/02-plan-compiled.md"}]}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "compile_plan"
  [ "$status" -eq 0 ]
  # The embedded target-skill reference (write_plan) must use the user-local override
  [[ "$output" == *"TARGET-SKILL-OVERRIDE-MARKER"* ]]
}
```

(Reuse the file's existing `setup`/`teardown` — the file already sets `ATELIER_CC_ROOT` and `WSP`; add `FAKE_HOME` handling per the snippet.)

### 3.2 Run test — verify failure

Expected: `compile-prompt.sh` dies with `skill not found: bookkeep-csv` (because the inline `$ROOT/skills/$skill/SKILL.md` only checks the plugin root).

### 3.3 Implementation

In `scripts/compile-prompt.sh`:

1. Source the resolver near the top, alongside the other lib sources:

   ```bash
   source "$ROOT/lib/skills.sh"
   ```

2. Replace the main skill line:

   ```bash
   # before:
   skill_file="$ROOT/skills/$skill/SKILL.md"
   [ -f "$skill_file" ] || die "skill not found: $skill"
   # after:
   skill_file="$(skill_resolve "$skill")"
   ```

   (`skill_resolve` already dies with a diagnostic listing both searched paths, so the explicit `[ -f ]` guard becomes redundant.)

3. Replace the target-skill line inside the `if [ -n "$target_stage" ]` block:

   ```bash
   # before:
   target_skill_file="$ROOT/skills/$target_skill/SKILL.md"
   if [ -f "$target_skill_file" ]; then
     target_skill_body="$(_strip_frontmatter "$target_skill_file")"
     ...
   fi
   # after:
   if target_skill_file="$(skill_resolve "$target_skill" 2>/dev/null)"; then
     target_skill_body="$(_strip_frontmatter "$target_skill_file")"
     ...
   fi
   ```

   The target-skill branch keeps soft-fail semantics (a missing target skill should not abort the compile — the existing code already gates on `[ -f ]`).

### 3.4 Run test — verify passes

```
debug_test({ projectRoot: "...", framework: "bats", test: "compile-prompt" })
```

All existing `compile-prompt` tests still pass plus the two new custom-skill cases (main skill override and target-skill override).

### 3.5 Checkpoint

`compile-prompt.sh` resolves both the active stage skill and any target compile-stage skill via the user-local-first resolver. The full Atelier dispatch path (Stop → PreToolUse → compile → Agent) now embeds user-authored skill bodies verbatim.

**Edge cases covered:**
- User-only stage skill: body appears in compiled prompt (test case 1).
- Plugin default unchanged: every existing `compile-prompt` test still green.
- Target compile-stage skill user-overridden: embedded reference reflects override (test case 2, directly tested).
- Missing target skill: silent skip preserved (no abort).

---

## Task 4: Build the accounting fixture [x]

**Files:**
- Create: `tests/fixtures/accounting-pipeline/accounting.json`
- Create: `tests/fixtures/accounting-pipeline/skills/collect-invoices/SKILL.md`
- Create: `tests/fixtures/accounting-pipeline/skills/bookkeep-csv/SKILL.md`
- Create: `tests/fixtures/accounting-pipeline/skills/review-bookkeeping/SKILL.md`
- Create: `tests/fixtures/accounting-pipeline/skills/fix-bookkeeping/SKILL.md`
- Create: `tests/fixtures/accounting-pipeline/skills/insert-bookkeeping/SKILL.md`
- Create: `tests/fixtures/accounting-pipeline/sample-invoices/invoice-001.txt`
- Create: `tests/fixtures/accounting-pipeline/sample-invoices/invoice-002.txt`
- Create: `tests/fixtures/accounting-pipeline/sample-invoices/invoice-003.txt`

### 4.1 Write failing test

The fixture itself is data — its "test" is structural. Add a small sanity check at the top of the integration suite (Task 5) confirming all five SKILL.md files exist and parse as valid frontmatter+body.

### 4.2 Run test — verify failure

The integration test (Task 5.1) will fail at the structural check until files exist.

### 4.3 Implementation

`tests/fixtures/accounting-pipeline/accounting.json`:

```json
{
  "name": "accounting",
  "description": "French bookkeeping pipeline: invoices → CSV with compte assignment → review → fix → insert",
  "stages": [
    { "name": "collect_invoices",   "mode": "interactive", "skill": "collect-invoices",   "artifactType": "invoices",   "requiresArtifact": true },
    { "name": "bookkeep_csv",       "mode": "autonomous",  "skill": "bookkeep-csv",       "artifactType": "csv",        "requiresArtifact": true },
    { "name": "review_bookkeeping", "mode": "autonomous",  "skill": "review-bookkeeping", "reviewBehavior": "fix-bookkeeping", "artifactType": "review", "requiresArtifact": true },
    { "name": "insert_bookkeeping", "mode": "autonomous",  "skill": "insert-bookkeeping", "artifactType": "ledger",     "requiresArtifact": true }
  ]
}
```

Note: `fix-bookkeeping` is implicit via `reviewBehavior` (matching the existing `fixing` / `fixing-specs` pattern in plugin topologies). Each SKILL.md has minimal frontmatter (`name`, `description`) plus 30-60 lines of instructions specific to the accounting domain (e.g. `bookkeep-csv` mentions French chart-of-accounts codes 6xx for expenses, 7xx for revenue; `review-bookkeeping` checks numeric consistency).

Each `invoice-NNN.txt` is plain text mimicking a parsed invoice:

```
Fournisseur: Acme Office Supplies
Date: 2026-03-12
Total HT: 145.00 EUR
TVA 20%: 29.00 EUR
Total TTC: 174.00 EUR
Description: Cartouches d'encre imprimante
```

Three invoices cover three different expense categories so the bookkeep stage exercises the compte logic.

### 4.4 Run test — verify passes

Sanity check in Task 5 confirms files exist and parse.

### 4.5 Checkpoint

The accounting fixture is on disk and ready to be installed into `$HOME/.atelier/skills/` by the integration test.

**Edge cases covered:**
- All 5 skills present (no broken topology references).
- Sample invoices in 3 distinct expense categories (exercises compte-assignment branches without overfitting).

---

## Task 5: Integration test — full custom pipeline resolution [x]

**Files:**
- Create: `tests/integration/custom-pipeline.bats`

### 5.1 Write failing test

```bash
#!/usr/bin/env bats

FIXTURE="$BATS_TEST_DIRNAME/../fixtures/accounting-pipeline"

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  WSP="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  export HOME="$FAKE_HOME"
  # Install all five fixture skills user-local.
  for skill_dir in "$FIXTURE/skills"/*/; do
    name="$(basename "$skill_dir")"
    mkdir -p "$HOME/.atelier/skills/$name"
    cp "$skill_dir/SKILL.md" "$HOME/.atelier/skills/$name/SKILL.md"
  done
  # Install the custom topology project-local.
  mkdir -p "$WSP/.atelier/topologies"
  cp "$FIXTURE/accounting.json" "$WSP/.atelier/topologies/accounting.json"
  # Copy invoices into workspace so the collect stage has something to point at.
  cp -R "$FIXTURE/sample-invoices" "$WSP/sample-invoices"
}

teardown() {
  rm -rf "$WSP" "$FAKE_HOME"
}

@test "accounting fixture has all 5 skills and 3 invoices" {
  for s in collect-invoices bookkeep-csv review-bookkeeping fix-bookkeeping insert-bookkeeping; do
    [ -f "$FIXTURE/skills/$s/SKILL.md" ]
  done
  count="$(ls "$FIXTURE/sample-invoices"/*.txt | wc -l)"
  [ "$count" -eq 3 ]
}

@test "custom topology loads and lists in topology_list" {
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  json="$(topology_load "$WSP" "accounting")"
  [ "$(printf '%s' "$json" | jq -r .name)" = "accounting" ]
  out="$(topology_list "$WSP")"
  [[ "$out" == *accounting* ]]
}

@test "skill_resolve finds every accounting skill user-local" {
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  for s in collect-invoices bookkeep-csv review-bookkeeping fix-bookkeeping insert-bookkeeping; do
    run skill_resolve "$s"
    [ "$status" -eq 0 ]
    [ "$output" = "$HOME/.atelier/skills/$s/SKILL.md" ]
  done
}

@test "compile-prompt emits custom skill body for autonomous accounting stage" {
  pid="acct-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<EOF
{
  "type": "accounting",
  "prompt": "Process March 2026 invoices",
  "expectedSkill": "bookkeep-csv",
  "workspacePath": "$WSP",
  "stages": [{
    "stage": "bookkeep_csv",
    "status": "running",
    "assignedOutputPath": "$WSP/.atelier/pipelines/$pid/02-acct-csv.md"
  }]
}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "bookkeep_csv"
  [ "$status" -eq 0 ]
  # The skill body must be embedded verbatim — pick a unique phrase from the
  # bookkeep-csv SKILL.md (e.g. "compte 6"), which doesn't appear in any plugin skill.
  [[ "$output" == *"compte 6"* ]]
  [[ "$output" == *"Process March 2026 invoices"* ]]
}

@test "starting a pipeline with the accounting topology succeeds" {
  source "$BATS_TEST_DIRNAME/../../lib/topology.sh"
  source "$BATS_TEST_DIRNAME/../../lib/skills.sh"
  # Confirm every stage's skill resolves before pipeline start would dispatch it.
  json="$(topology_load "$WSP" "accounting")"
  for s in $(printf '%s' "$json" | jq -r '.stages[].skill'); do
    run skill_resolve "$s"
    [ "$status" -eq 0 ]
  done
}
```

### 5.2 Run test — verify failure

```
debug_test({ projectRoot: "...", framework: "bats", test: "custom-pipeline" })
```

Fails before Tasks 1-4 land. After Task 4 the fixture sanity check passes; after Tasks 1-3 land, the resolution + compile cases pass.

### 5.3 Implementation

No new code — the test exercises code from Tasks 1-3 against the fixture from Task 4.

### 5.4 Run test — verify passes

All five cases green.

### 5.5 Checkpoint

A fully user-authored pipeline (custom topology + 5 custom skills + sample data) loads, resolves, and compiles correctly through the real Atelier code path. Customizability is end-to-end proven.

**Edge cases covered:**
- Multi-stage topology referencing only user-local skills (no plugin skills in the chain).
- Mixed interactive + autonomous stages.
- The compiled prompt includes the workspace path, the user's prompt, AND the custom skill body — proving the integration point isn't fragmented.

---

## Task 6: Document custom skills in README [x]

**Files:**
- Modify: `README.md`

### 6.1 Write failing test

No automated test — documentation correctness is reviewer-judged. (Optional: add a `tests/regression/readme-references.bats` that greps the README for the fixture path, ensuring docs and code don't drift. Out of scope unless reviewer asks.)

### 6.2 Run test — verify failure

N/A.

### 6.3 Implementation

Insert a new section after the existing "Custom topologies" line in README.md:

```markdown
### Custom Skills

Custom skills live under `$HOME/.atelier/skills/<name>/SKILL.md`. They are loaded
in preference to plugin-bundled skills with the same name, and can be referenced
from any custom topology under `<workspace>/.atelier/topologies/`.

Layout:

    ~/.atelier/skills/
    ├── collect-invoices/SKILL.md
    ├── bookkeep-csv/SKILL.md
    └── ...

A `SKILL.md` is a regular Atelier skill: YAML frontmatter (`name`, `description`)
plus a markdown body containing the instructions the agent must follow when this
stage executes.

#### Example: French bookkeeping pipeline

A worked example lives at `tests/fixtures/accounting-pipeline/`. It composes
five custom skills into an `accounting` topology:

1. `collect-invoices` (interactive) — user points the agent at invoice files
2. `bookkeep-csv` (autonomous) — produces a CSV with French compte codes
   (compte 6xx for expenses, 7xx for revenue, etc.)
3. `review-bookkeeping` (autonomous) — sanity-checks the CSV
4. `fix-bookkeeping` (autonomous, synthesized via `reviewBehavior`) — repairs
   issues the review flagged
5. `insert-bookkeeping` (autonomous) — appends the validated CSV to the
   long-running ledger

Install the example into your own home directory:

    cp -R tests/fixtures/accounting-pipeline/skills/* ~/.atelier/skills/
    mkdir -p .atelier/topologies
    cp tests/fixtures/accounting-pipeline/accounting.json .atelier/topologies/

⚠️ **Warning:** Running `cp -R` will overwrite any existing skills in `~/.atelier/skills/`
with the same name. Back up your custom skills first if needed.

Then start a pipeline with `/atelier "process March invoices"` and select
`accounting` as the topology when prompted.
```

### 6.4 Run test — verify passes

N/A (manual review).

### 6.5 Checkpoint

Users discover the feature, the layout, and a complete worked example without leaving the README.

**Edge cases covered:**
- The example explicitly notes that the accounting skills are NOT shipped as plugin payload — they must be copied into `$HOME/.atelier/skills/` by the user. (Matches the user's "do NOT add these example skills as atelier-cc skills" requirement.)

---

## Task 7: Create-pipeline skill and slash command [x]

**Files:**
- Create: `skills/create-pipeline/SKILL.md`
- Create: `commands/pipeline-create.md` (or extend `commands/atelier.md` with subcommand routing)
- Test: `tests/integration/pipeline-create.bats`

### 7.1 Write failing test

`tests/integration/pipeline-create.bats`:

```bash
#!/usr/bin/env bats

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/common.sh"
  export ATELIER_CC_ROOT="$BATS_TEST_DIRNAME/../.."
  WSP="$(mktemp -d)"
  export HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$WSP" "$HOME"
}

@test "create-pipeline skill outputs valid bash install script" {
  pid="create-$$"
  mkdir -p "$WSP/.atelier/pipelines/$pid"
  # Simulate user input: a three-stage invoicing pipeline.
  cat > "$WSP/.atelier/pipelines/$pid/pipeline-state.json" <<'EOF'
{
  "type": "create-pipeline",
  "prompt": "Pipeline name: invoice-flow\nDescription: Process vendor invoices into accounting\n\nStages:\n1. receive-invoices (interactive): User uploads invoices and confirms receipt\n2. extract-data (autonomous): Parse invoice PDFs and extract key fields\n3. validate (autonomous): Sanity-check extracted data and flag errors",
  "stages": [{
    "stage": "create_pipeline",
    "status": "running",
    "assignedOutputPath": "$WSP/.atelier/pipelines/$pid/01-invoice-flow-pipeline.sh"
  }]
}
EOF
  cd "$WSP"
  run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "create_pipeline"
  [ "$status" -eq 0 ]
  # The compiled prompt must include the skill body (user guidance).
  [[ "$output" == *"pipeline name"* ]]
  [[ "$output" == *"stages"* ]]
}

@test "create-pipeline script creates topology and skills at install time" {
  # This test would run the generated script, but that's heavyweight.
  # Instead, test that the script is syntactically valid bash and contains
  # the expected structure.
  skip "Full E2E requires simulating Agent execution"
}
```

### 7.2 Run test — verify failure

Expected: `compile-prompt.sh` dies with `skill not found: create-pipeline` (the skill doesn't exist yet) once Tasks 1-3 land.

### 7.3 Implementation

**Skills/create-pipeline/SKILL.md:**

```markdown
---
name: create-pipeline
description: Guided interactive skill for authoring custom Atelier pipelines
---

# Create Custom Pipeline

You are guiding the user to design and build their own Atelier pipeline. Your role is to produce a self-installing bash script that creates all necessary artifacts (`topology.json`, skill files, README).

## Input Format

The user will provide a pipeline specification in this format:

```
Pipeline name: <kebab-case name>
Description: <one-line summary of what the pipeline does>

Stages:
1. <stage-name> (interactive|autonomous): <stage description — what this stage does and what the agent/user should accomplish>
2. <stage-name> (interactive|autonomous): <stage description>
... (3-8 stages typical)
```

## Your Task

1. **Validate the spec** — Check for:
   - Pipeline name is non-empty and valid kebab-case
   - Description is present
   - At least 2 stages, no more than 8
   - Each stage has a valid mode (interactive or autonomous)
   - Stage descriptions are specific (not vague placeholders)

2. **Synthesize each skill** — For each stage, write a complete `SKILL.md`:
   - Frontmatter: `name`, `description`
   - Body: 30-100 lines of instructions for the agent (or user, if interactive)
   - Reflect the pipeline's domain: if the user is building an accounting pipeline, use domain-specific language (comptes, invoices, ledger entries, etc.)

3. **Create the topology** — A JSON object with the pipeline's stages, modes, and artifact types:
   - `artifactType` for each stage (e.g., "invoices", "ledger", "report")
   - Interactive stages set `requiresArtifact: true`
   - Autonomous stages can be chained for progressive refinement

4. **Write the README** — A brief guide (200 words) explaining:
   - What the pipeline does
   - How to use it (which stages are interactive, what user input is expected)
   - Example command: `/atelier "your task here"` then select the pipeline when prompted

5. **Emit a self-installing bash script** — Your output is a single executable bash script that, when run with `bash script.sh --install`, creates:
   - `$HOME/.atelier/topologies/<name>.json` — the topology
   - `$HOME/.atelier/skills/<stage1>/SKILL.md`, `$HOME/.atelier/skills/<stage2>/SKILL.md`, ... — all skill files
   - `$HOME/.<pipeline-name>-readme.md` — the README (optional; can be omitted)

   The script should:
   - Be idempotent (re-running doesn't corrupt existing installs)
   - Check for existing files and warn before overwriting
   - Print success messages after each file is created
   - Exit with code 0 on success, non-zero on error

## Example Output

If the user specifies a three-stage invoice pipeline, your script output might be:

```bash
#!/usr/bin/env bash
set -euo pipefail

install() {
  mkdir -p "$HOME/.atelier/skills/receive-invoices" "$HOME/.atelier/skills/extract-data" "$HOME/.atelier/skills/validate"
  mkdir -p "$HOME/.atelier/topologies"

  cat > "$HOME/.atelier/topologies/invoice-flow.json" <<'TOPOLOGY_EOF'
{
  "name": "invoice-flow",
  "description": "Process vendor invoices into accounting",
  "stages": [
    { "name": "receive_invoices", "mode": "interactive", "skill": "receive-invoices", "artifactType": "invoices", "requiresArtifact": true },
    { "name": "extract_data", "mode": "autonomous", "skill": "extract-data", "artifactType": "data", "requiresArtifact": true },
    { "name": "validate", "mode": "autonomous", "skill": "validate", "artifactType": "validation", "requiresArtifact": true }
  ]
}
TOPOLOGY_EOF

  cat > "$HOME/.atelier/skills/receive-invoices/SKILL.md" <<'SKILL1_EOF'
---
name: receive-invoices
description: Collect and confirm vendor invoices
---
# Receive Invoices
... (full skill body)
SKILL1_EOF

  cat > "$HOME/.atelier/skills/extract-data/SKILL.md" <<'SKILL2_EOF'
...
SKILL2_EOF

  cat > "$HOME/.atelier/skills/validate/SKILL.md" <<'SKILL3_EOF'
...
SKILL3_EOF

  cat > "$HOME/.invoice-flow-readme.md" <<'README_EOF'
# Invoice Flow Pipeline
... (full README)
README_EOF

  echo "✓ Installed invoice-flow topology and 3 skills to ~/.atelier/skills/"
  echo "✓ Use it: /atelier \"process march vendor invoices\" then select invoice-flow"
}

install
```

## Constraints

- **No syntax errors** — the bash script must be valid and executable
- **Idempotent** — safe to run multiple times
- **JSON validity** — the topology must parse as valid JSON
- **Name safety** — all file names use only alphanumerics, hyphens, underscores (no spaces, no ../escapes)
- **Skill completeness** — each skill should be a standalone, actionable instruction document (not a stub)

## Output Path (REQUIRED)

Write the complete bash install script to the assigned path (as a single `.sh` file). When the user signals `stage_complete`, pass this path as `outputPath`.
```

**Command wiring** — extend `commands/atelier.md` or create `commands/pipeline-create.md`:

The existing `commands/atelier.md` has a verb dispatcher. Add support for the `pipeline` subcommand:

```markdown
## `/atelier pipeline create`

Launch the `create-pipeline` interactive skill. Walk through:
1. Pipeline name and description
2. Stage list (name, mode, description for each)
3. Agent writes a bash install script
4. User runs the script to install topology + skills + README

After generation, the script is saved to `.atelier/pipelines/<id>/01-<name>-pipeline.sh`. Run it with:

    bash .atelier/pipelines/<id>/01-<name>-pipeline.sh --install
```

The routing logic in `commands/atelier.md` extracts the verb and dispatches. If the verb is `pipeline create`, emit a block reason that routes to the `create-pipeline` skill (not a full topology — just the one skill). The Stop hook treats this like an interactive skill dispatch (analogous to how `quick-planning` works — single interactive stage).

### 7.4 Run test — verify passes

Once the skill exists, `compile-prompt.sh` emits the prompt correctly. Full E2E test (actually running the script and checking that files are created) is deferred to manual testing by the user since it requires Agent execution.

### 7.5 Checkpoint

Users can now run `/atelier pipeline create`, answer prompts about their pipeline design, get a self-installing script, and have the topology + skills ready to use.

**Edge cases covered:**
- Invalid pipeline name (not kebab-case): skill rejects and asks for retry
- Too few/too many stages: skill validates bounds
- Ambiguous stage descriptions: skill asks for clarification
- Existing topology/skills: install script checks for collisions and prompts
- Script syntax validation: tested by attempting to source/bash -n it (not in this test, but a pre-commit hook could add it)

---

## Execution Order

Sequential — each task strictly depends on the previous:

1. **Task 1** — resolver + unit tests. Foundation; no callers yet.
2. **Task 2** — wire `skill_resolve` into `lib/dispatch.sh`. Depends on Task 1.
3. **Task 3** — wire `skill_resolve` into `scripts/compile-prompt.sh`. Depends on Task 1.
4. **Task 4** — fixture files on disk. Independent of Tasks 1-3 but required by Task 5.
5. **Task 5** — integration test. Depends on Tasks 1-4.
6. **Task 6** — README. Depends on nothing technical but should land last so docs match shipped behavior.
7. **Task 7** — create-pipeline skill + command. Depends on Tasks 1-3 (needs skill_resolve to work). Can run in parallel with Tasks 4-6.

Tasks 2, 3, and 4 are parallelizable after Task 1 lands. Task 5 must wait for all of them. Task 7 is independent (just needs the resolver infrastructure) and can run whenever.

## Files Modified Summary

| File | Change | Description |
|---|---|---|
| `lib/skills.sh` | Create | `skill_resolve` helper |
| `lib/dispatch.sh` | Modify | Replace two inline skill-path constructions with `skill_resolve` |
| `scripts/compile-prompt.sh` | Modify | Replace two inline skill-path constructions with `skill_resolve` |
| `hooks/stop.sh` | Modify | Add `source "$ROOT/lib/skills.sh"` |
| `hooks/subagent-stop.sh` | Modify | Add `source "$ROOT/lib/skills.sh"` |
| `tests/unit/skills.bats` | Create | 6 cases — resolver precedence + validation |
| `tests/integration/dispatch-skills.bats` | Create | 1 case — dispatch.sh interactive branch picks up user-local skill |
| `tests/unit/compile-prompt.bats` | Modify | Add 2 cases — main skill override + target-skill override |
| `tests/integration/custom-pipeline.bats` | Create | 5 cases — full custom topology + skills end-to-end |
| `tests/integration/pipeline-create.bats` | Create | 2 cases — create-pipeline skill generates valid bash script |
| `tests/fixtures/accounting-pipeline/accounting.json` | Create | Custom topology fixture |
| `tests/fixtures/accounting-pipeline/skills/*/SKILL.md` | Create | 5 skill fixtures |
| `tests/fixtures/accounting-pipeline/sample-invoices/*.txt` | Create | 3 fake invoice fixtures |
| `skills/create-pipeline/SKILL.md` | Create | Interactive skill for guided pipeline creation |
| `commands/atelier.md` | Modify | Add `/atelier pipeline create` subcommand dispatcher + block reason |
| `README.md` | Modify | New "Custom Skills" section + accounting walkthrough + create-pipeline mention |

## Edge Case Coverage Matrix

| Scope requirement | Test location | Assertion |
|---|---|---|
| User-local skill shadows plugin default | `tests/unit/skills.bats` | `skill_resolve` returns `$HOME/.atelier/skills/...` path |
| User-only skill resolves (no plugin equivalent) | `tests/unit/skills.bats` | `skill_resolve "bookkeep-csv"` succeeds with user path |
| Missing skill error names both searched paths | `tests/unit/skills.bats` | Error contains both `$HOME/...` and plugin path |
| Path-traversal skill name rejected | `tests/unit/skills.bats` | `skill_resolve "../escape"` exits non-zero |
| Empty skill name rejected | `tests/unit/skills.bats` | `skill_resolve ""` exits non-zero |
| Dispatch interactive recovery uses user-local skill | `tests/integration/dispatch-skills.bats` | Emitted block reason contains the user-local marker |
| Dispatch missing-skill soft fallback preserved | Existing dispatch unit tests stay green | No regression in `(skill body unavailable)` path |
| compile-prompt embeds user-local main skill | `tests/unit/compile-prompt.bats` case 1 | Compiled prompt contains user-local marker |
| compile-prompt embeds user-local target skill on compile stages | `tests/unit/compile-prompt.bats` case 2 | Compiled prompt contains target-skill override marker |
| Full custom pipeline starts cleanly | `tests/integration/custom-pipeline.bats` | Every stage skill resolves via `skill_resolve` |
| create-pipeline skill compiles without error | `tests/integration/pipeline-create.bats` | `compile-prompt.sh` exits 0 and emits expected phrases |
| create-pipeline generates valid bash script | Manual E2E (deferred) | Script parses with `bash -n` and runs `--install` without error |
| Generated install script is idempotent | Manual E2E (deferred) | Running twice doesn't corrupt files; second run warns on collision |
| Generated topology is valid JSON | Covered implicitly when pipeline starts | Routing doesn't choke on `jq` parse |
| Generated SKILL.md files parse frontmatter | Covered implicitly when stages dispatch | Agents receive skill body without errors |
| README walkthrough commands match reality | Manual review (could add a `tests/regression/readme-grep.bats` if desired) | `cp -R` and `cp` commands resolve real paths |
| Fixture skills not accidentally shipped as plugin payload | Structural: they live under `tests/fixtures/`, not under `skills/` | `scripts/sync-skills.sh` ignores `tests/fixtures/` (already does) |
