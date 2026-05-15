# Quick Plan Review: User-local custom skills for atelier-cc

## Verdict: **has_issues**

The plan is well-structured and comprehensive, but contains scope creep and several medium-severity gaps that should be addressed before implementation begins.

---

## Critical Issues

### 1. Task 7 (create-pipeline skill) is out of scope

**Problem:** Task 7 adds a full interactive skill + command wiring for guided pipeline creation. This is **not mentioned in the original Scope section** and represents significant additional scope beyond the stated goal.

**Location:** Plan lines 649–872

**Current scope claim:** "Make atelier-cc fully user-customizable by letting users author their own skills under `$HOME/.atelier/skills/<name>/SKILL.md` and reference them from custom topologies"

**What Task 7 adds:** An interactive skill (`create-pipeline`) + command dispatcher (`/atelier pipeline create`) that guides users through designing new pipelines interactively and generates a self-installing bash script.

**Why this matters:** The core feature (user-local skill resolution) is complete without Task 7. Task 7 is a convenience feature that doubles the implementation surface (new skill + new command routing) and should either be:
- Moved to a separate "Phase 2" plan, or
- Explicitly added to the Scope section with a note that it's an expansion

**Suggested fix:** Either:
1. **Move Task 7 out of this plan.** Document it as "Future: interactive pipeline creation (out of scope for this phase)."
2. **Update the Scope section** to explicitly include "Interactive pipeline creation skill + command" as a new in-scope item, and justify why it's being bundled with the core resolver feature.

Recommend option 1 (defer to a separate phase) — the resolver is valuable standalone, and Task 7 adds risk without immediate user benefit.

---

## High Issues

### 2. Target-skill override in compile-prompt is not directly tested

**Problem:** The plan's Task 3 test only covers the **main skill** override when calling `compile-prompt.sh`. The plan's Architecture section mentions that `target_skill_file` can also be overridden for compile-* stages, but the test doesn't exercise this.

**Location:**
- Architecture description (lines 34–36): mentions target skill override implicitly
- Task 3 test (lines 293–317): only tests main skill override
- Coverage matrix (line 922): claims "covered indirectly" but doesn't specify how

**Why this matters:** If `target_skill_file` lookup is changed but the test doesn't cover it, a user-local target skill override could silently break.

**Current test code:**
```bash
run "$ATELIER_CC_ROOT/scripts/compile-prompt.sh" "$pid" "bookkeep_csv"
[ "$status" -eq 0 ]
[[ "$output" == *"USER-CUSTOM-BOOKKEEP-MARKER"* ]]
```

This only checks the main skill body, not the target-skill embedding.

**Suggested fix:** Extend Task 3 to add a second test case for a compile-* stage with a user-overridden target skill:
- Use a `compile_plan` stage (or another compile-* variant)
- Verify that the target skill body (embedded in the `stage_skill_block`) comes from the user-local override, not the plugin default
- Example assertion: `[[ "$output" == *"TARGET-SKILL-OVERRIDE-MARKER"* ]]`

---

### 3. Dispatch.sh integration pattern not verified

**Problem:** The plan assumes dispatch.sh interactive branches call `skill_resolve`, but doesn't verify that dispatch.sh is always sourced before those branches execute. The plan says to "rely on callers having sourced it" but then adds sourcing to hooks/stop.sh and hooks/subagent-stop.sh.

**Location:** Plan lines 238–262 (Task 2 implementation notes)

**Concern:** If dispatch.sh is also called from other places (e.g., other scripts), those callers may not source lib/skills.sh, causing dispatch.sh to fail silently or error out.

**Current approach in stop.sh:**
```bash
source "$ROOT/lib/common.sh"
source "$ROOT/lib/pipeline-state.sh"
source "$ROOT/lib/topology.sh"
source "$ROOT/lib/routing.sh"
source "$ROOT/lib/dispatch.sh"
```

**Suggested fix:** 
1. Add a check in dispatch.sh itself:
   ```bash
   # Near the top of lib/dispatch.sh, after the module comment
   _dispatch_ensure_skills_loaded() {
     command -v skill_resolve >/dev/null || source "${BASH_SOURCE[0]%/*}/skills.sh"
   }
   _dispatch_ensure_skills_loaded
   ```
2. OR explicitly verify all callers of dispatch.sh in a pre-implementation audit

---

## Medium Issues

### 4. Line number references are inaccurate (minor impact)

**Problem:** The plan references line numbers in dispatch.sh that are off by several lines.

**Location:** Plan lines 179 and 179 (Task 2 implementation)

**Actual code:**
- Plan says "line 95 for dispatch_reemit_existing" → actual skill_file assignment is at line 106
- Plan says "line 175 for _dispatch_emit" → actual skill_file assignment is at line 186

**Why this matters:** A fixer agent following the plan's exact line numbers will miss the target. However, the function names and code context are correct, so a careful implementation won't be derailed.

**Suggested fix:** Update the plan's line number references to match the actual file:
- Line 106 for dispatch_reemit_existing
- Line 186 for _dispatch_emit

---

### 5. Test setup in Task 2 is heavy for a "unit" test

**Problem:** The Task 2 test creates a full custom topology + pipeline state + fixtures, which is more integration-style than pure unit testing. This makes the test slower and couples it to the broader pipeline machinery.

**Location:** Plan lines 200–214 (Task 2.1 setup)

**Current approach:**
```bash
mkdir -p "$WSP/.atelier/topologies"
cat > "$WSP/.atelier/topologies/acct.json" <<EOF
{"name":"acct",...}
EOF
mkdir -p "$HOME/.atelier/skills/collect-x"
```

**Suggestion:** This is acceptable if it's labeled as a "minimal integration test" rather than a "unit test". The plan could:
1. Clarify that Task 2 is actually an integration test (acceptable — it exercises dispatch.sh in context)
2. OR simplify it by mocking fewer pieces (e.g., manually set up the needed state variables instead of creating topology JSON)

**Suggested fix:** Rename Task 2's test file from `tests/unit/dispatch-skills.bats` to `tests/integration/dispatch-skills.bats` to reflect its actual scope.

---

### 6. Accounting fixture may be unnecessarily complex

**Problem:** Five skills + three invoices + a full topology for a test fixture is substantial. While it serves double duty (test data + README walkthrough), it makes the codebase heavier.

**Location:** Plan lines 386–450 (Task 4)

**Trade-off:** The fixture is good for documentation (an actual worked example), but five skills is a lot to maintain as fixture code. The plan could:
1. Keep the full example for the README walkthrough (good for user discovery)
2. Create a simpler two-skill fixture for the integration test (cheaper to maintain)

**Suggested fix:** Consider splitting into two fixtures:
- `tests/fixtures/simple-pipeline/` — a two-stage skeleton for the core integration test
- `tests/fixtures/accounting-pipeline/` — the full five-stage example for the README walkthrough

This is optional — the current approach is acceptable if the fixture is truly treated as reference documentation.

---

## Low Issues

### 7. Fixture deployment instructions could be clearer

**Problem:** The plan's README section (Task 6) tells users to `cp -R tests/fixtures/accounting-pipeline/skills/* ~/.atelier/skills/`, but doesn't warn that this will overwrite existing skills with the same name.

**Location:** Plan lines 625–634

**Suggested fix:** Add a note in the README:
```markdown
⚠️ **Warning:** This will overwrite any existing skills in `~/.atelier/skills/` with the same name. Back up your work first if needed.
```

---

### 8. create-pipeline skill design is aspirational

**Problem:** The Task 7 skill (lines 710–836) asks the agent to produce a "complete bash install script" with complex logic (idempotency, collision detection, etc.). This is ambitious and may not work reliably on the first try.

**Location:** Plan lines 710–836

**Why:** Agent-generated bash scripts are error-prone, especially for tasks like idempotent file creation and JSON generation. The skill's "Output Path (REQUIRED)" instruction implies a very specific script format.

**Suggested fix:** If keeping Task 7, simplify the skill requirements:
- Have the agent output individual files (topology JSON, skill frontmatter, README) as separate artifacts
- Let the user manually run a simple `install.sh` template that assembles them
- OR: provide a hardcoded install-script generator in bash that takes agent outputs as structured input

But this is moot if Task 7 is deferred (which is recommended).

---

## Summary Table

| Issue | Severity | Type | Blocker? |
|-------|----------|------|----------|
| Task 7 scope creep | Critical | Scope | **Yes** |
| Target-skill override not tested | High | Coverage | **Yes** |
| Dispatch.sh caller pattern unverified | High | Architecture | Maybe |
| Line numbers inaccurate | Medium | Documentation | No |
| Task 2 labeled "unit" but is integration | Medium | Classification | No |
| Fixture complexity | Medium | Design | No |
| Collision warning missing from docs | Low | Docs | No |
| create-pipeline skill is ambitious | Low | Feasibility | No |

---

## Recommendations Before Implementation

**Must fix before starting:**
1. **Defer Task 7** to a separate phase, or update the Scope section to explicitly include it.
2. **Add a direct test for target-skill override** in Task 3.
3. **Verify dispatch.sh caller pattern** — audit all scripts that source dispatch.sh and confirm they'll have lib/skills.sh in scope.

**Should fix:**
4. Update line number references in the plan to match actual code (lines 106, 186 in dispatch.sh).
5. Reclassify Task 2's test as an integration test (move to `tests/integration/`).

**Nice to have:**
6. Add collision warning to README documentation.
7. Consider splitting the accounting fixture into simple + full variants.

---

## Positive Observations

✓ **Architecture approach is sound** — mirroring `topology_load`'s precedence pattern is clean and idiomatic.

✓ **Test matrix is comprehensive** — the edge case coverage section is well-thought-out.

✓ **Execution order is clear** — task dependencies and parallelization opportunities are documented.

✓ **Integration test design is good** — Task 5's multi-stage pipeline exercise proves end-to-end correctness.

✓ **Documentation is good** — README walkthrough will help users discover the feature.

---

## Conclusion

The plan is **98% ready to implement**. The critical blocker is Task 7's scope creep; the core resolver feature (Tasks 1–6) is well-designed and should proceed once scope is clarified. Fix the three "must fix" items and the plan is solid.
