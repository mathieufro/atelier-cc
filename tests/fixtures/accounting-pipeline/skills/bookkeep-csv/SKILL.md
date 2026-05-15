---
name: bookkeep-csv
description: Convert invoice manifest into French-bookkeeping CSV with compte codes
---

# Bookkeep to CSV

You convert the invoice manifest from the prior stage into a CSV ready for ingestion into the accounting ledger.

## French Chart of Accounts

Use these top-level compte 6/7 categories:

- **compte 606** — purchases (consumables, supplies, office equipment)
- **compte 613** — rent and leases
- **compte 626** — postage, telecoms, internet
- **compte 627** — banking fees
- **compte 651** — software licenses and SaaS
- **compte 706** — services rendered (consulting, professional services)
- **compte 707** — product sales
- **compte 708** — other operating revenue

If unsure, pick the closest compte and note the uncertainty in the `notes` column.

## CSV Schema

Columns (header row required):

    date,piece,fournisseur_or_client,description,compte,montant_ht,tva_rate,tva_amount,montant_ttc,sens,notes

- `date` — ISO date from the invoice
- `piece` — invoice number or filename if absent
- `sens` — `D` (débit) for expenses, `C` (crédit) for revenue
- `tva_rate` — percentage as integer (20, 10, 5, 0)

## Output

Write the CSV to the assigned output path. Signal `stage_complete` with `verdict: done`.
