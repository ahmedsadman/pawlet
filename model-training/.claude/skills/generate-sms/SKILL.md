---
name: generate-sms
description: Use when the user pastes a real bank SMS (with its sender) and wants synthetic variants or training rows for the Pawlet SMS model dataset (model-training/data/sms-dataset-v1.jsonl), e.g. because the on-device classifier misses, drops or mislabels that bank message format.
---

# generate-sms

## Overview

Turn one real SMS into X training rows where **only the values change**. Boilerplate, punctuation, spacing, line
breaks, mask shapes and number formatting stay exactly as in the original.

**Core rule: you choose values and labels; `smsgen.py` does every character-level job.** It locates fields,
checks shapes and grouping, computes spans, scalars and ids, and runs the repo validator. Never count offsets,
eyeball shapes or pick a `message_id` yourself.

Spec format, label rules and dataset schema: `reference.md` (same directory). Helper: `smsgen.py` (stdlib,
`python3`). In the commands below, `$S` is the absolute path of `smsgen.py` in this skill's directory. Its
dataset defaults to `model-training/data/sms-dataset-v1.jsonl`, so the commands work from any directory.

## Workflow

1. **Collect** the exact SMS text, the sender, X and any custom instructions. If X is missing, use **10** and say
   so; earlier per-format batches used 20. Before writing the spec, check the instructions against the
   conflict rules below (read-only digging in the dataset is fine).
2. **Study the format.** Grep the dataset for the sender and similar wording. Decide `category`/`type` using the
   table in `reference.md`, `currency_span` from rows of the same format, and `grouping` if the original's numbers
   are ambiguous.
3. **Write the spec** to `/tmp/generate-sms-<slug>-<YYYYmmdd-HHMMSS>.spec.json`. The slug is the sender in
   lowercase, with each run of characters other than letters and digits turned into one `-` and none left at the
   ends. Copy the original verbatim. Use one spec, and one review file, per seed SMS; when there are several
   seeds, add `-a`, `-b` to the slug.
4. **`python3 $S scan SPEC`**: every value that should vary must be a field. FIXED tokens (helpline numbers etc.)
   stay as they are.
5. **Fill `variants`**, then run **`python3 $S render SPEC`**. Fix every PROBLEM by changing the *values*. Never
   loosen the spec to get it through: switching a field to `free`, deleting a field or overriding `grouping`
   against the evidence all count as loosening.
6. **STOP.** Give the user the review `.md` path (it sits next to the spec), a one-line summary and any NOTEs, then
   wait. Edits mean editing the spec and re-rendering to the same path. Drops are applied at append. If a reply
   only edits, show the re-rendered review and wait again. If it edits and approves in the same message,
   re-render and continue.
7. **Only after explicit approval:** run `python3 $S append <stem>.rows.jsonl [--drop V2,V5]`. Then run
   `python3 scripts/validate_dataset.py` from `model-training/` and fix anything it reports. Update the count line
   in the README "Data" section to the validator's numbers. Give the user the follow-up command from
   `reference.md`. **Don't split, train or commit.**

## Choosing values

- Vary everything that is a value: amounts across magnitudes, balances, masked digits, dates, times, refs and
  merchants. No two variants may share content.
- Keep the values plausible and consistent with each other:
  - dates must be real and in order (a due date falls after its statement month);
  - credits leave a balance at least as large as the amount;
  - meaningful patterns survive: an "incl. charges" amount like `250,010.00` usually keeps a fee-like tail.
- Merchants and payees should look realistic and be fictional.

## Custom instructions

Follow them unless they break format fidelity. When one does, **say so and ask before generating**; don't
quietly drop it or bend it.

| Instruction | Verdict |
|---|---|
| "amounts above 1 lakh", "use these merchants", "dates in 2025" | Fine, within the format |
| "make half credits" on a debit SMS; "use lakh commas" on a western-grouped SMS; "add a balance" | **Conflict.** It changes boilerplate or formatting. Offer: a real credit SMS from that bank as its own seed, an existing same-bank format from the dataset (as a second spec, with that format's sender spelling), or (only if the user accepts an invented wording) a `choice` field |

## Red flags: stop

| Thought | Reality |
|---|---|
| "User's in a hurry, skip the review" | The review is the approval gate. Render it and wait. |
| "I'll write a generator script in `scripts/` like `gen_city_amex.py`" | That's what `smsgen.py` is for. Touch only the dataset and the README count line. |
| "Next id after 10060 is free" | Synthetic variants continue the 900000+ block, and `append` assigns them. |
| "This instruction is close enough, I'll adapt it" | Name the conflict and ask. |
| "Re-split so the rows are used" | Hand the user the command; don't run it. |
