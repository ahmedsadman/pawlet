# generate-sms reference

## Spec file (input to `smsgen.py`)

```json
{
  "sender": "BRAC-BANK",
  "original": "Tk 250,010.00 (incl. charges) has been debited ... Helpline:16221",
  "instructions": "optional: the user's custom instructions, shown in the review",
  "labels": {"category": "transaction", "type": "expense",
             "currency": "BDT", "currency_span": "Tk"},
  "grouping": "western",
  "fields": {
    "amount":    {"value": "250,010.00", "kind": "money", "span": "amount_span"},
    "from_acct": {"value": "1**0001"},
    "balance":   {"value": "1,327,551.29", "kind": "money", "span": "balance_span"}
  },
  "variants": [
    {"amount": "48,010.00", "from_acct": "3**0002", "balance": "2,91,004.18",
     "labels": {"type": "expense"}, "note": "optional reviewer note"}
  ]
}
```

- `original`: the SMS exactly as pasted. JSON-escape it (`\n` for line breaks, keep double spaces).
- `fields`: every value that varies. `value` is the text exactly as it appears in `original`. The script finds it
  there. It must sit on token boundaries, so `0001` will not match inside `1**0001`.
  - If the value appears more than once, set `"occurrence": N` (1-based) or `"all"`. Use `"all"` when one value
    repeats and must change everywhere together. A span field must claim exactly one occurrence.
  - Anything not claimed by a field is boilerplate and stays byte-identical. `scan` lists the digit tokens that
    are still FIXED.
- `labels`: the base labels for every variant. A variant may override them with its own `labels`.
- `grouping` (`plain` | `western` | `indian`): needed only when the original's numbers can't settle it (for
  example `15,000` or `500`). Take it from rows of the same format; if none of them settle it, use the same
  sender's other formats, and say so in the review summary. A per-field `grouping` overrides it when a real SMS
  mixes styles.
- Each variant must give every field, and nothing else except `labels` and `note`.

### Field kinds (the format-fidelity rules)

| kind | variant must | use for |
|---|---|---|
| `shape` (default) | have the identical shape: digit→`9`, `A-Z`→`A`, `a-z`→`a`, everything else literal (`*`, `#`, `X`, `x`, punctuation, spaces) | masked card/account numbers, reference numbers, client ids, codes |
| `money` | keep the same decimal count and the message's grouping (lakh `1,86,567` vs western `186,567` vs plain `186567`), no leading zero; digit count may change | amounts, balances, dues |
| `date` + `format` | keep the same shape and parse with Python `strptime(format)` | dates, times, statement periods (`%b %Y`, `%d-%b-%y`, `%I:%M %p`, `%H:%M`, `%b'%y`) |
| `free` | be non-empty with no line break | merchant/payee names |
| `choice` + `choices` | be one of `choices` (the original must be one too) | only after the user explicitly accepts a boilerplate change (see SKILL.md) |

A span field must be `money` for `amount_span`, `balance_span` and `total_due_span`, and `date` for
`statement_span`.

### What the script derives (never type these yourself)

- `content`: built from the original's literal segments plus the variant values. Rebuilding with the original
  values must reproduce the original byte-for-byte.
- Span `{text, start, end}`: recorded while `content` is built.
- Scalars: `amount`, `balance` and `total_due` are the span text with commas removed. `statement_month` and
  `statement_year` are parsed from the statement span using its `format`.
- `message_id`: assigned at append time.
- Checks: the repo's own `validate_dataset.check()` runs on the dataset plus the new rows before anything is
  written.

## Dataset schema (`data/sms-dataset-v1.jsonl`)

One JSON object per line. `sender` is metadata; the model trains on `content` only. Key order per category:

| category | keys |
|---|---|
| `"transaction"` | `message_id, sender, content, category, type, amount, currency, balance, amount_span, balance_span, currency_span` |
| `"bill"` | `message_id, sender, content, category, total_due, currency, statement_month, statement_year, total_due_span, statement_span` |
| `null` | `message_id, sender, content, category`: no spans and no scalars |

- **Span** = `{"text", "start", "end"}`, character offsets into `content`, with `content[start:end] == text`.
  It covers the number only, never the currency token: in `Tk. 1,327,551.29.` the span text is `1,327,551.29`.
- **Scalar** = span text with commas removed, decimals exactly as printed: `"250,010.00"` → `"250010.00"`,
  `"37.5"` → `"37.5"`.
- **`balance`**: the available/current balance printed in the SMS (for card messages too). If the SMS shows no
  balance, both `balance` and `balance_span` are `null`.
- **`currency`**: ISO code. Tk, TK, Tk. and BDT all map to `"BDT"`; USD maps to `"USD"`.
- **`currency_span`** is a plain string, not offsets. It is the currency token written before the amount, but
  copy whatever existing rows of the same format use. The CITY BANK `Tk.` rows store `"Tk"`, the CITY AMEX
  payment rows store `"Tk."`, and USD rows store `null`. Training ignores it (`src/config.py`).
- **Bills**: `total_due_span` is the total due, never the minimum due. If both show the same number, it is the
  first occurrence. `statement_span` is the period text (`AUG 2026`, `JUL2026`, `Jan'25`).

### Choosing `category` and `type` (account holder's view)

| SMS says | label |
|---|---|
| debited from the user's account; purchase; withdrawal; outgoing fund/NPSB transfer; tax or fees; paying a card bill *from* a bank account | `transaction` / `expense` |
| credited or deposited to the user's account; incoming NPSB; interest; merchant return or refund | `transaction` / `income` |
| a payment received or credited *on a credit card* (card bill repaid) | `transaction` / `transfer` |
| a card statement with a total due and a statement period | `bill` |
| OTP, promo, info, dunning or min-due reminder without a statement period | `null` |

Settle any doubt by finding rows of the same sender or format: `grep '"sender": "BRAC-BANK"'`. `render` also
lists the ids of rows that share the original's exact format.

### `message_id` ranges

| range | contents |
|---|---|
| `< 10000` | real SMS (real ids; 9001/9002 are manual real rows) |
| `10001-10060` | City AMEX batch from `scripts/gen_city_amex.py` |
| `200001+` | synthetic null rows |
| `900001+` | synthetic value-variants of real formats, which is what this skill makes |

`smsgen.py append` gives new rows contiguous ids from `max(id in 900000-999999) + 1`. It reads them from the live
file at append time and refuses on any collision. The review shows only V-labels. Never pick ids by hand.

## Splits and follow-up

- `data/splits/{train,val,test}.jsonl` are gitignored outputs of `python -m src.split`. Each row is placed
  70/15/15 per class by `sha1(SEED:content)`.
- There is no pinning: `_split` was removed, so never add it. Appended rows reach training only after a
  re-split.
- Don't run split or training yourself. Give the user this, run from `model-training/` with its venv active:

  ```
  python scripts/validate_dataset.py && python -m src.split && python -m src.train_fused && python -m src.evaluate
  ```

  Then, to ship: `python -m src.export_onnx && python scripts/export_tflite.py`.
