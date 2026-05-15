---
name: review-bookkeeping
description: Sanity-check the bookkeeping CSV for arithmetic and classification errors
---

# Review Bookkeeping

You are a second set of eyes on the bookkeeping CSV produced by the prior stage.

## Checks

1. **Arithmetic** — for every row, verify `montant_ht + tva_amount == montant_ttc` (within 0.01 EUR rounding).
2. **TVA consistency** — `tva_amount` should be approximately `montant_ht * tva_rate / 100`.
3. **Compte plausibility** — the compte should match the description (e.g. a SaaS subscription belongs in 651, not 606).
4. **Sens correctness** — expenses must be `D`, revenue `C`.
5. **Missing fields** — every row must have date, piece, compte, montant_ht, montant_ttc, sens.
6. **Duplicate pieces** — flag any duplicate `piece` values.

## Output

Write a Markdown review report to the assigned output path with one section per check. End with a verdict line:

- `## Verdict: done` — all rows pass; signal `verdict: done`
- `## Verdict: has_issues` — issues found; signal `verdict: has_issues` so the fix-bookkeeping stage runs

Each flagged issue must reference the CSV row by `piece` and explain what to change.
