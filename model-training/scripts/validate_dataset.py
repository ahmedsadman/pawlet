"""Check the dataset's invariants. Run before split/train.

The dataset is hand-curated now, so nothing regenerates it and nothing re-checks
it. A span that is off by one character, or a scalar that disagrees with the text
it was extracted from, trains the NER on a wrong answer silently — this script is
the only thing standing between a bad row and a bad model.

Reports every problem it finds, then exits non-zero.

  python scripts/validate_dataset.py
"""
import json
import sys
from collections import Counter

DATASET = "data/sms-dataset-v1.jsonl"

CATEGORIES = {"transaction", "bill", None}
TXN_TYPES = {"expense", "income", "transfer"}

# span key -> the scalar field it must agree with (None = no scalar)
SPAN_SCALARS = {
    "amount_span": "amount",
    "balance_span": "balance",
    "total_due_span": "total_due",
    "statement_span": None,
}


def check_span(errs, rec, key):
    """Span offsets slice out exactly the stored text, and the scalar matches."""
    sp = rec.get(key)
    if sp is None:
        return
    mid, content = rec["message_id"], rec["content"]
    if not (0 <= sp["start"] < sp["end"] <= len(content)):
        errs.append(f"{mid}: {key} offsets out of range {sp['start']}-{sp['end']}")
        return
    if content[sp["start"]:sp["end"]] != sp["text"]:
        errs.append(f"{mid}: {key} slices {content[sp['start']:sp['end']]!r}, "
                    f"stored {sp['text']!r}")
    scalar = SPAN_SCALARS[key]
    if scalar and rec.get(scalar) != sp["text"].replace(",", ""):
        errs.append(f"{mid}: {scalar}={rec.get(scalar)!r} does not match "
                    f"{key} text {sp['text']!r}")


def check(rows):
    errs = []
    ids, contents = Counter(), Counter()

    for rec in rows:
        mid = rec.get("message_id")
        ids[mid] += 1
        contents[rec.get("content")] += 1

        if not rec.get("content"):
            errs.append(f"{mid}: empty content")
            continue
        if not rec.get("sender"):
            errs.append(f"{mid}: empty sender")

        cat = rec.get("category")
        if cat not in CATEGORIES:
            errs.append(f"{mid}: unknown category {cat!r}")

        if cat == "transaction":
            if rec.get("type") not in TXN_TYPES:
                errs.append(f"{mid}: bad transaction type {rec.get('type')!r}")
            if not rec.get("amount_span"):
                errs.append(f"{mid}: transaction without amount_span")
            if (rec.get("balance") is None) != (rec.get("balance_span") is None):
                errs.append(f"{mid}: balance and balance_span disagree on presence")
            if not rec.get("currency"):
                errs.append(f"{mid}: transaction without currency")
        elif cat == "bill":
            if not rec.get("total_due_span"):
                errs.append(f"{mid}: bill without total_due_span")
            if not rec.get("statement_span"):
                errs.append(f"{mid}: bill without statement_span")
            if not 1 <= (rec.get("statement_month") or 0) <= 12:
                errs.append(f"{mid}: bad statement_month {rec.get('statement_month')!r}")
            if not 2000 <= (rec.get("statement_year") or 0) <= 2099:
                errs.append(f"{mid}: bad statement_year {rec.get('statement_year')!r}")
        else:  # null: carries no extracted fields
            present = [k for k in SPAN_SCALARS if rec.get(k)]
            if present:
                errs.append(f"{mid}: null record carries spans {present}")

        for key in SPAN_SCALARS:
            check_span(errs, rec, key)

    for mid, n in ids.items():
        if n > 1:
            errs.append(f"duplicate message_id {mid} ({n} rows)")
    for content, n in contents.items():
        if n > 1:
            errs.append(f"duplicate content ({n} rows): {content[:60]!r}")

    return errs


def leaf(rec):
    if rec.get("category") == "bill":
        return "bill"
    if rec.get("category") is None:
        return "null"
    return rec.get("type")


def main():
    rows = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]
    errs = check(rows)

    print(f"{len(rows)} rows, by leaf: {dict(Counter(leaf(r) for r in rows))}")
    if errs:
        print(f"\n{len(errs)} PROBLEMS:")
        for e in errs:
            print(" ", e)
        sys.exit(1)
    print("OK")


if __name__ == "__main__":
    main()
