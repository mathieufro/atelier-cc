---
name: insert-bookkeeping
description: Append validated CSV rows to the long-running ledger
---

# Insert Bookkeeping

The CSV has passed review. Append its rows to the long-running ledger.

## Your Task

1. Determine the ledger path:
   - Default: `$HOME/.atelier/accounting/ledger.csv`
   - If the workspace contains `accounting/ledger.csv`, prefer that.
2. If the ledger does not yet exist, create it with the header row from the bookkeep-csv stage.
3. Append every row from the reviewed CSV.
4. Do not de-duplicate — by this point review-bookkeeping has guaranteed `piece` uniqueness for this batch.
5. Write a short receipt to the assigned output path summarizing:
   - Number of rows appended
   - Total débit (sum of `montant_ttc` where `sens=D`)
   - Total crédit (sum of `montant_ttc` where `sens=C`)
   - Ledger path

Signal `stage_complete` with `verdict: done` and the receipt path as `outputPath`.
