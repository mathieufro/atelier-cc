---
name: collect-invoices
description: Interactive collection of invoice files for bookkeeping
---

# Collect Invoices

You are guiding the user through gathering the set of vendor and customer invoices to be booked.

## Your Task

1. Ask the user where the invoices live (a directory, a list of files, or a folder of PDFs/images).
2. Confirm the period being booked (e.g. "March 2026").
3. Produce a single manifest file at the assigned output path listing each invoice with:
   - `path` — absolute path to the invoice file
   - `type` — "vendor" (expense) or "customer" (revenue)
   - `notes` — any user-provided context (e.g. "this one is split between Q1 and Q2")

The manifest is plain Markdown with one bullet per invoice.

## Output Format

```markdown
# Invoices — March 2026

- /abs/path/invoice-001.txt (vendor) — Office supplies, Acme
- /abs/path/invoice-002.txt (vendor) — SaaS subscription
- /abs/path/invoice-003.txt (customer) — Consulting Q1
```

Signal `stage_complete` with `verdict: done` and the manifest path as `outputPath`.
