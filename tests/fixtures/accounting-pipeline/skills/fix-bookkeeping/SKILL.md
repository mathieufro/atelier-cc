---
name: fix-bookkeeping
description: Apply review-bookkeeping fixes to the CSV
---

# Fix Bookkeeping

The review-bookkeeping stage flagged issues in the CSV. Your job is to apply the fixes and produce a corrected CSV.

## Your Task

1. Read the prior `review-bookkeeping` artifact — it lists each issue with the `piece` reference.
2. Read the original CSV from the bookkeep-csv stage.
3. For each flagged row, apply the fix described in the review:
   - Recompute arithmetic if `montant_ttc` mismatched.
   - Re-classify the compte if the review proposed a different one.
   - Correct `sens` if revenue/expense was swapped.
   - Resolve duplicates by renaming or merging as the review directs.
4. Preserve untouched rows verbatim.

## Output

Write the corrected CSV to the assigned output path (same schema as bookkeep-csv).

Signal `stage_complete` with `verdict: done`. The pipeline will then loop back into `review-bookkeeping` for a re-check.
