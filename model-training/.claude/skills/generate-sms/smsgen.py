#!/usr/bin/env python3
"""generate-sms helper: format-faithful SMS variants -> review markdown -> dataset rows.

Stdlib only. Every character-level decision (where a value sits in the SMS, span
offsets, whether a variant kept the original's shape) is made here, mechanically.

  python3 smsgen.py scan   SPEC                 # list digit/mask tokens + which fields claim them
  python3 smsgen.py render SPEC [--dataset P]   # check variants, write SPEC-stem.md + .rows.jsonl
  python3 smsgen.py append ROWS [--drop V2,V5] [--dataset P]   # append approved rows

SPEC is JSON (see reference.md next to this script). The dataset defaults to
model-training/data/sms-dataset-v1.jsonl; its sibling scripts/validate_dataset.py
is imported so the repo's own invariants are checked before anything is written.
"""
import argparse
import importlib.util
import json
import re
import sys
from datetime import datetime
from pathlib import Path

MT_ROOT = Path(__file__).resolve().parents[3]  # .../model-training
DEFAULT_DATASET = MT_ROOT / "data" / "sms-dataset-v1.jsonl"

# Synthetic value-variants of real formats live in the 900000+ block (the block
# the original "faithful real-format variants" rows used). New ids continue it.
ID_BLOCK = (900000, 1000000)

SPAN_SCALAR = {"amount_span": "amount", "balance_span": "balance",
               "total_due_span": "total_due", "statement_span": None}
KINDS = {"shape", "money", "date", "free", "choice"}
MASK_CHARS = "*#"
KEEP_LITERAL = "Xx"  # mask letters: kept literal in shapes so X can't become A


class SpecError(Exception):
    pass


# --------------------------------------------------------------------------- #
# character classes / shapes
# --------------------------------------------------------------------------- #
def cclass(ch):
    if ch.isdigit():
        return "d"
    if ch.isalpha():
        return "a"
    if ch in MASK_CHARS:
        return "m"
    return None


def shape(s):
    """Digits -> 9, A-Z -> A, a-z -> a (except mask letters X/x), rest literal."""
    out = []
    for ch in s:
        if ch.isdigit():
            out.append("9")
        elif ch in KEEP_LITERAL:
            out.append(ch)
        elif "A" <= ch <= "Z":
            out.append("A")
        elif "a" <= ch <= "z":
            out.append("a")
        else:
            out.append(ch)
    return "".join(out)


def boundary_ok(s, a, b):
    """A located value must not be a fragment of a larger token/number."""
    if a > 0:
        c = cclass(s[a - 1])
        if c and c == cclass(s[a]):
            return False
        if s[a - 1] in ",." and a > 1 and s[a - 2].isdigit() and s[a].isdigit():
            return False
    if b < len(s):
        c = cclass(s[b])
        if c and c == cclass(s[b - 1]):
            return False
        if s[b] in ",." and b + 1 < len(s) and s[b + 1].isdigit() and s[b - 1].isdigit():
            return False
    return True


def ctx(s, a, b, pad=12):
    return repr(s[max(0, a - pad):a] + "[" + s[a:b] + "]" + s[b:b + pad])


# --------------------------------------------------------------------------- #
# money grouping
# --------------------------------------------------------------------------- #
WESTERN_RE = re.compile(r"\d{1,3}(?:,\d{3})+")
INDIAN_RE = re.compile(r"\d{1,2}(?:,\d{2})*,\d{3}")
MONEY_RE = re.compile(r"(\d[\d,]*)(?:\.(\d+))?")


def indian(digits):
    if len(digits) <= 3:
        return digits
    last3, rest, parts = digits[-3:], digits[:-3], []
    while len(rest) > 2:
        parts.insert(0, rest[-2:])
        rest = rest[:-2]
    if rest:
        parts.insert(0, rest)
    return ",".join(parts + [last3])


def group(digits, style):
    if style == "plain":
        return digits
    if style == "western":
        return "{:,}".format(int(digits))
    return indian(digits)


def money_split(v):
    m = MONEY_RE.fullmatch(v)
    if not m:
        return None
    return m.group(1), m.group(2)


def grouping_evidence(intpart):
    """What the integer part tells us: plain|western|indian|grouped(ambiguous)|any."""
    digits = intpart.replace(",", "")
    if "," not in intpart:
        return "plain" if len(digits) >= 4 else "any"
    w, i = WESTERN_RE.fullmatch(intpart), INDIAN_RE.fullmatch(intpart)
    if w and i:
        return "grouped"
    if w:
        return "western"
    if i:
        return "indian"
    return "invalid"


# --------------------------------------------------------------------------- #
# spec
# --------------------------------------------------------------------------- #
def load_spec(path):
    spec = json.loads(Path(path).read_text(encoding="utf-8"))
    for key in ("sender", "original", "labels", "fields"):
        if key not in spec:
            raise SpecError(f"spec missing '{key}'")
    return spec


def locate_fields(spec, errs):
    """-> list of (start, end, field_name) over the original, sorted."""
    orig = spec["original"]
    ranges = []
    for name, f in spec["fields"].items():
        val = f.get("value")
        if not val:
            errs.append(f"field {name}: missing 'value'")
            continue
        raw = [m.start() for m in re.finditer(re.escape(val), orig)]
        hits = [h for h in raw if boundary_ok(orig, h, h + len(val))]
        occ = f.get("occurrence")
        if not hits:
            why = (f" (found only inside larger tokens: "
                   f"{', '.join(ctx(orig, h, h + len(val)) for h in raw)})" if raw else "")
            errs.append(f"field {name}: {val!r} not found in original{why}")
            continue
        if occ is None:
            if len(hits) > 1:
                errs.append(f"field {name}: {val!r} occurs {len(hits)} times "
                            f"({'; '.join(ctx(orig, h, h + len(val)) for h in hits)}). "
                            f"Set \"occurrence\": N (1-based) or \"all\".")
                continue
            chosen = hits
        elif occ == "all":
            chosen = hits
        elif isinstance(occ, int) and 1 <= occ <= len(hits):
            chosen = [hits[occ - 1]]
        else:
            errs.append(f"field {name}: bad occurrence {occ!r} ({len(hits)} hits)")
            continue
        if f.get("span") and len(chosen) > 1:
            errs.append(f"field {name}: a span field must claim exactly one occurrence")
            continue
        for h in chosen:
            ranges.append((h, h + len(val), name))
    ranges.sort()
    for (a1, b1, n1), (a2, b2, n2) in zip(ranges, ranges[1:]):
        if a2 < b1:
            errs.append(f"fields {n1} and {n2} overlap in the original")
    return ranges


def resolve_groupings(spec, errs):
    """field name -> plain|western|indian for every money field."""
    money = {n: f for n, f in spec["fields"].items() if f.get("kind") == "money"}
    evidence = {}
    for n, f in money.items():
        parts = money_split(f["value"])
        if not parts:
            errs.append(f"field {n}: money value {f['value']!r} is not a number")
            continue
        ev = grouping_evidence(parts[0])
        if ev == "invalid":
            errs.append(f"field {n}: {f['value']!r} has irregular digit grouping")
            continue
        evidence[n] = ev
    strong = {e for n, e in evidence.items()
              if e in ("plain", "western", "indian") and not money[n].get("grouping")}
    msg_style = spec.get("grouping")
    if not msg_style:
        if len(strong) == 1:
            msg_style = next(iter(strong))
        elif len(strong) > 1:
            errs.append(f"original mixes money groupings {sorted(strong)}; "
                        f"set \"grouping\" on each money field")
    out = {}
    for n, ev in evidence.items():
        style = money[n].get("grouping") or msg_style
        if not style:
            hint = ("western or indian" if ev == "grouped"
                    else "plain, western or indian")
            errs.append(f"field {n}: grouping of {money[n]['value']!r} is ambiguous; "
                        f"set top-level \"grouping\" ({hint}) from other SMS of this "
                        f"sender/format in the dataset")
            continue
        if style not in ("plain", "western", "indian"):
            errs.append(f"field {n}: unknown grouping {style!r}")
            continue
        ok = {"plain": ("plain", "any"), "western": ("western", "grouped", "any"),
              "indian": ("indian", "grouped", "any")}[style]
        if ev not in ok:
            errs.append(f"field {n}: original {money[n]['value']!r} is not {style}-grouped")
            continue
        out[n] = style
    return out


def check_value(name, f, val, style, errs, where):
    """Variant value vs the field's original: the format-fidelity rules."""
    orig = f["value"]
    kind = f.get("kind", "shape")
    if not isinstance(val, str) or not val:
        errs.append(f"{where} {name}: empty or non-string value {val!r}")
        return
    if "\n" in val and "\n" not in orig:
        errs.append(f"{where} {name}: value contains a line break")
        return
    if kind in ("shape", "date"):
        if shape(val) != shape(orig):
            errs.append(f"{where} {name}: shape {shape(val)!r} != original "
                        f"{shape(orig)!r} ({val!r} vs {orig!r})")
            return
        if kind == "date":
            try:
                datetime.strptime(val, f["format"])
            except ValueError:
                errs.append(f"{where} {name}: {val!r} is not a valid date for "
                            f"format {f['format']!r}")
    elif kind == "money":
        parts, oparts = money_split(val), money_split(orig)
        if not parts:
            errs.append(f"{where} {name}: {val!r} is not a number")
            return
        ip, dec = parts
        digits = ip.replace(",", "")
        if (dec is None) != (oparts[1] is None) or (dec and len(dec) != len(oparts[1])):
            errs.append(f"{where} {name}: decimals of {val!r} differ from original {orig!r}")
        if len(digits) > 1 and digits[0] == "0":
            errs.append(f"{where} {name}: leading zero in {val!r}")
        if style and ip != group(digits, style):
            errs.append(f"{where} {name}: integer part of {val!r} should be "
                        f"{style}-grouped as {group(digits, style)!r}")
    elif kind == "choice":
        if val not in f.get("choices", []):
            errs.append(f"{where} {name}: {val!r} not in choices {f.get('choices')}")


def validate_spec_fields(spec, errs):
    cat = spec["labels"].get("category", "MISSING")
    if cat not in ("transaction", "bill", None):
        errs.append(f"labels.category {cat!r} must be transaction, bill or null")
    spans = {}
    for n, f in spec["fields"].items():
        kind = f.get("kind", "shape")
        if kind not in KINDS:
            errs.append(f"field {n}: unknown kind {kind!r}")
        if kind == "date":
            if not f.get("format"):
                errs.append(f"field {n}: date field needs a strptime 'format'")
            else:
                try:
                    datetime.strptime(f["value"], f["format"])
                except ValueError:
                    errs.append(f"field {n}: original {f['value']!r} does not parse "
                                f"with format {f['format']!r}")
        if kind == "choice" and f.get("value") not in f.get("choices", []):
            errs.append(f"field {n}: original value must be one of its choices")
        sp = f.get("span")
        if sp:
            if sp not in SPAN_SCALAR:
                errs.append(f"field {n}: unknown span {sp!r}")
            elif sp in spans:
                errs.append(f"span {sp} claimed by both {spans[sp]} and {n}")
            else:
                spans[sp] = n
            if sp == "statement_span" and kind != "date":
                errs.append(f"field {n}: statement_span must be a date field "
                            f"(month/year are parsed from it)")
            if sp in ("amount_span", "balance_span", "total_due_span") and kind != "money":
                errs.append(f"field {n}: {sp} must be a money field")
    need = {"transaction": {"amount_span"}, "bill": {"total_due_span", "statement_span"},
            None: set()}.get(cat, set())
    allowed = {"transaction": {"amount_span", "balance_span"},
               "bill": {"total_due_span", "statement_span"}, None: set()}.get(cat, set())
    for sp in need - set(spans):
        errs.append(f"category {cat} needs a field with \"span\": \"{sp}\"")
    for sp in set(spans) - allowed:
        errs.append(f"category {cat} must not carry {sp}")
    return spans


# --------------------------------------------------------------------------- #
# rows
# --------------------------------------------------------------------------- #
def build_content(orig, ranges, values):
    out, spans_at, pos = [], {}, 0
    length = 0
    for a, b, name in ranges:
        lit = orig[pos:a]
        out.append(lit)
        length += len(lit)
        v = values[name]
        spans_at.setdefault(name, []).append((length, length + len(v)))
        out.append(v)
        length += len(v)
        pos = b
    out.append(orig[pos:])
    return "".join(out), spans_at


def make_row(spec, labels, content, spans_at, values, span_fields):
    def span(sp):
        name = span_fields.get(sp)
        if not name:
            return None
        (a, b), = spans_at[name]
        assert content[a:b] == values[name]
        return {"text": content[a:b], "start": a, "end": b}

    cat = labels.get("category")
    row = {"message_id": None, "sender": labels.get("sender", spec["sender"]),
           "content": content, "category": cat}
    if cat == "transaction":
        amt, bal = span("amount_span"), span("balance_span")
        row.update({
            "type": labels.get("type"),
            "amount": amt["text"].replace(",", ""),
            "currency": labels.get("currency"),
            "balance": bal["text"].replace(",", "") if bal else None,
            "amount_span": amt, "balance_span": bal,
            "currency_span": labels.get("currency_span"),
        })
    elif cat == "bill":
        due, st = span("total_due_span"), span("statement_span")
        when = datetime.strptime(st["text"], spec["fields"][span_fields["statement_span"]]["format"])
        row.update({
            "total_due": due["text"].replace(",", ""),
            "currency": labels.get("currency"),
            "statement_month": when.month, "statement_year": when.year,
            "total_due_span": due, "statement_span": st,
        })
    return row


def load_validator(dataset):
    path = Path(dataset).resolve().parent.parent / "scripts" / "validate_dataset.py"
    if not path.exists():
        raise SpecError(f"validator not found at {path}")
    sys.dont_write_bytecode = True  # don't drop a __pycache__ into the repo's scripts/
    mod_spec = importlib.util.spec_from_file_location("validate_dataset", path)
    mod = importlib.util.module_from_spec(mod_spec)
    mod_spec.loader.exec_module(mod)
    return mod


def read_rows(path):
    return [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]


def next_ids(existing, n):
    taken = {r["message_id"] for r in existing}
    block = [m for m in taken if isinstance(m, int) and ID_BLOCK[0] <= m < ID_BLOCK[1]]
    start = (max(block) if block else ID_BLOCK[0]) + 1
    ids = list(range(start, start + n))
    if ids and (ids[-1] >= ID_BLOCK[1] or taken & set(ids)):
        raise SpecError("message_id block exhausted or colliding; pick a new range")
    return ids


def same_format(orig, ranges, existing):
    """Ids of dataset rows whose content has exactly the original's literal text."""
    lits, pos = [], 0
    for a, b, _ in ranges:
        lits.append(orig[pos:a])
        pos = b
    lits.append(orig[pos:])
    rx = re.compile("(.+?)".join(re.escape(l) for l in lits), re.S)
    return [r["message_id"] for r in existing if rx.fullmatch(r["content"])]


def repo_check(dataset, new_rows):
    existing = read_rows(dataset)
    vmod = load_validator(dataset)
    errs = vmod.check(existing + new_rows)
    return existing, errs


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def digit_tokens(orig):
    for m in re.finditer(r"\S+", orig):
        tok = m.group(0)
        if any(c.isdigit() or c in MASK_CHARS for c in tok):
            yield m.start(), m.end(), tok


def cmd_scan(args):
    spec = load_spec(args.spec)
    errs = []
    ranges = locate_fields(spec, errs)
    orig = spec["original"]
    covered = set()
    for a, b, _ in ranges:
        covered.update(range(a, b))
    print(f"original: {len(orig)} chars, {orig.count(chr(10)) + 1} line(s)")
    print("fields:")
    for a, b, name in ranges:
        print(f"  {name:<14} {a:>4}-{b:<4} {orig[a:b]!r}  shape {shape(orig[a:b])!r}")
    print("digit/mask tokens:")
    for a, b, tok in digit_tokens(orig):
        fixed = "".join(orig[i] if i not in covered and orig[i].isdigit() else " "
                        for i in range(a, b)).split()
        state = "FIXED" if not any(i in covered for i in range(a, b)) else (
            "partly fixed " + repr(fixed) if fixed else "covered")
        print(f"  {a:>4} {tok!r:<28} {state}")
    for e in errs:
        print("ERROR:", e)
    return 1 if errs else 0


def cmd_render(args):
    spec = load_spec(args.spec)
    errs = []
    span_fields = validate_spec_fields(spec, errs)
    ranges = locate_fields(spec, errs)
    styles = resolve_groupings(spec, errs)
    orig = spec["original"]
    variants = spec.get("variants") or []
    if not variants:
        errs.append("spec has no variants")
    if errs:
        return fail(errs)

    # round trip: the original values must rebuild the original byte-for-byte
    base_vals = {n: f["value"] for n, f in spec["fields"].items()}
    rebuilt, _ = build_content(orig, ranges, base_vals)
    assert rebuilt == orig, "internal: template round trip failed"

    rows, warns = [], []
    for i, var in enumerate(variants, 1):
        where = f"V{i}"
        extra = set(var) - set(spec["fields"]) - {"labels", "note"}
        missing = set(spec["fields"]) - set(var)
        if extra:
            errs.append(f"{where}: unknown keys {sorted(extra)}")
        if missing:
            errs.append(f"{where}: missing fields {sorted(missing)}")
            continue
        for n, f in spec["fields"].items():
            check_value(n, f, var[n], styles.get(n), errs, where)
            if var[n] == f["value"]:
                warns.append(f"{where} {n}: same as the original ({var[n]!r})")
        labels = dict(spec["labels"], **(var.get("labels") or {}))
        content, spans_at = build_content(orig, ranges, var)
        if content == orig:
            errs.append(f"{where}: identical to the original")
        row = make_row(spec, labels, content, spans_at, var, span_fields)
        row["_v"] = where
        row["_note"] = var.get("note")
        rows.append(row)
    if errs:
        return fail(errs)

    dataset = Path(args.dataset)
    ids = next_ids(read_rows(dataset), len(rows))
    probe = []
    for r, mid in zip(rows, ids):
        p = {k: v for k, v in r.items() if not k.startswith("_")}
        p["message_id"] = mid
        probe.append(p)
    existing, verrs = repo_check(dataset, probe)
    if verrs:
        return fail([f"validate_dataset: {e}" for e in verrs])
    seen = [r["message_id"] for r in existing if r["content"] == orig]
    if seen:
        warns.append(f"the original SMS is already in the dataset (id {seen[0]})")
    fmt_ids = same_format(orig, ranges, existing)
    warns.append(f"dataset has {len(fmt_ids)} row(s) in this exact format"
                 + (f": ids {fmt_ids[:12]}{' ...' if len(fmt_ids) > 12 else ''}"
                    if fmt_ids else ""))

    stem = re.sub(r"(\.spec)?\.json$", "", str(args.spec))
    md_path, rows_path = Path(stem + ".md"), Path(stem + ".rows.jsonl")
    with open(rows_path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    md_path.write_text(review_md(spec, ranges, styles, rows, ids, warns, dataset,
                                 len(existing), rows_path), encoding="utf-8")
    for w in warns:
        print("NOTE:", w)
    print(f"OK: {len(rows)} variants passed shape, span and validate_dataset checks")
    print(f"review: {md_path}")
    print(f"rows:   {rows_path}")
    return 0


def fence(text):
    return "```text\n" + text + "\n```"


def label_lines(r):
    sp = lambda s: f"`{s['text']}` @ {s['start']}-{s['end']}" if s else "null"
    cat = r["category"]
    if cat == "transaction":
        return [("category", "transaction"), ("type", r["type"]),
                ("amount", f"{r['amount']} (span {sp(r['amount_span'])})"),
                ("balance", f"{r['balance']} (span {sp(r['balance_span'])})"
                 if r["balance"] is not None else "null"),
                ("currency", r["currency"]), ("currency_span", json.dumps(r["currency_span"]))]
    if cat == "bill":
        return [("category", "bill"),
                ("total_due", f"{r['total_due']} (span {sp(r['total_due_span'])})"),
                ("statement", f"{r['statement_month']}/{r['statement_year']} "
                              f"(span {sp(r['statement_span'])})"),
                ("currency", r["currency"])]
    return [("category", "null (no extracted fields)")]


def review_md(spec, ranges, styles, rows, ids, warns, dataset, n_existing, rows_path):
    orig = spec["original"]
    covered = set()
    for a, b, _ in ranges:
        covered.update(range(a, b))
    fixed = [tok for a, b, tok in digit_tokens(orig)
             if not any(i in covered for i in range(a, b))]
    L = [f"# generate-sms review: {spec['sender']}", "",
         f"- Generated: {datetime.now():%Y-%m-%d %H:%M}",
         f"- Variants: {len(rows)}; dataset `{dataset}` has {n_existing} rows",
         f"- message_id: assigned at append from the live dataset, contiguous from {ids[0]} "
         f"if nothing else is appended first (drops shift later variants down)",
         f"- Staged rows: `{rows_path}`",
         "- Checks passed: field shapes, money grouping/decimals, date validity, "
         "spans by construction, `validate_dataset.check` on dataset + these rows", ""]
    if spec.get("instructions"):
        L += [f"**Custom instructions:** {spec['instructions']}", ""]
    L += ["## Original", "", f"Sender: `{spec['sender']}`", "", fence(orig), "",
          "| field | kind | original | label |", "|---|---|---|---|"]
    for n, f in spec["fields"].items():
        kind = f.get("kind", "shape")
        if kind == "money":
            kind += f" ({styles.get(n)})"
        if kind == "date":
            kind += f" (`{f['format']}`)"
        L.append(f"| {n} | {kind} | `{f['value']}` | {f.get('span') or ''} |")
    L += ["", "Fixed tokens left unchanged: " +
          (", ".join(f"`{t}`" for t in fixed) if fixed else "none"), ""]
    if warns:
        L += ["**Notes and warnings:**", ""] + [f"- {w}" for w in warns] + [""]
    L += ["## Variants", ""]
    for r, mid in zip(rows, ids):
        L += [f"### {r['_v']}", ""]
        if r.get("_note"):
            L += [f"_{r['_note']}_", ""]
        L += [fence(r["content"]), "", "| label | value |", "|---|---|"]
        L += [f"| {k} | {v} |" for k, v in label_lines(r)]
        L.append("")
    L += ["---", "Reply with edits, variants to drop (e.g. `drop V2`), or approval."]
    return "\n".join(L) + "\n"


def cmd_append(args):
    staged = read_rows(args.rows)
    drop = {d.strip() for d in (args.drop or "").split(",") if d.strip()}
    unknown = drop - {r["_v"] for r in staged}
    if unknown:
        return fail([f"--drop names unknown variants {sorted(unknown)}"])
    keep = [r for r in staged if r["_v"] not in drop]
    if not keep:
        return fail(["nothing left to append"])
    dataset = Path(args.dataset)
    ids = next_ids(read_rows(dataset), len(keep))
    new = []
    for r, mid in zip(keep, ids):
        row = {k: v for k, v in r.items() if not k.startswith("_")}
        row["message_id"] = mid
        new.append(row)
    _, verrs = repo_check(dataset, new)
    if verrs:
        return fail([f"validate_dataset: {e}" for e in verrs])
    raw = dataset.read_bytes()
    with open(dataset, "a", encoding="utf-8") as f:
        if raw and not raw.endswith(b"\n"):
            f.write("\n")
        for row in new:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")
    for r, row in zip(keep, new):
        print(f"appended {r['_v']} as message_id {row['message_id']}")
    print(f"{len(new)} rows appended to {dataset}")
    return 0


def fail(errs):
    print(f"{len(errs)} PROBLEM(S):")
    for e in errs:
        print("  -", e)
    return 1


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("scan")
    s.add_argument("spec")
    r = sub.add_parser("render")
    r.add_argument("spec")
    r.add_argument("--dataset", default=str(DEFAULT_DATASET))
    a = sub.add_parser("append")
    a.add_argument("rows")
    a.add_argument("--drop", help="comma-separated variant labels, e.g. V2,V5")
    a.add_argument("--dataset", default=str(DEFAULT_DATASET))
    args = ap.parse_args()
    try:
        return {"scan": cmd_scan, "render": cmd_render, "append": cmd_append}[args.cmd](args)
    except SpecError as e:
        return fail([str(e)])


if __name__ == "__main__":
    sys.exit(main())
