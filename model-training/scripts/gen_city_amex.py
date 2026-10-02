"""Generate City Bank AMEX rows (3 real SMS formats x 20 value variations).

The three formats come from real City Bank credit-card SMS; only the values are
synthetic (amounts, balances, card numbers, client ids, merchants, dates, links).
Layout, casing, punctuation and line breaks are reproduced exactly, since that
is what the model learns.

The script only ever appends; existing rows are never rewritten.

  python scripts/gen_city_amex.py           # dry run, prints every row
  python scripts/gen_city_amex.py --apply   # append to the dataset
"""
import json
import random
import sys

DATASET = "data/sms-dataset-v1.jsonl"
FIRST_ID = 10001  # unused range: existing ids are <10000, 200001+ and 900000+

MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

MERCHANTS = [
    "SWIFTMART", "NOORBAZAR ONLINE", "PIXELPLAY*SUBSCR", "URBANFUEL STN 42",
    "CHOLO RIDES", "GREENLEAF PHARMA", "AMAR BOOKSHOP", "NEXUS ELECTRONICS",
    "TASTEBUD CAFE", "ZAFFRAN KITCHEN", "SKYLINE AIRWAYS", "METRO RAIL TOPUP",
    "CLOUDNINE HOSTING", "PRIME FITNESS CLUB", "LUMEN GROCERS",
    "RIVERSIDE DINER", "BLUEWAVE TELECOM", "ORCHID FLORIST",
    "QUICKFIX HARDWARE", "SUNSET CINEMAS",
]

SHORTENERS = ["t.ly", "bit.ly", "cutt.ly", "s.id", "tiny.cc"]

# magnitude spread: a few hundred up to crore-scale, per the real range
EXPENSE_AMOUNTS = [
    149.00, 385.50, 920.00, 1275.75, 2450.00, 4899.99, 7320.40, 9150.00,
    13600.00, 18425.60, 27900.00, 42350.25, 68500.00, 95999.00, 128750.00,
    264300.50, 512000.00, 1340000.00, 6250000.00, 10000000.00,
]
EXPENSE_BALANCES = [
    1875.25, 6430.00, 11200.50, 24980.00, 38715.75, 57300.00, 84250.00,
    109600.00, 152400.30, 218900.00, 347500.00, 495600.80, 712300.00,
    988450.00, 1450000.00, 2360000.00, 4875000.00, 9120000.00, 18500000.00,
    52000000.00,
]
BILL_TOTALS = [
    320.00, 785.25, 1540.00, 3275.90, 5900.00, 8410.50, 12650.00, 19875.00,
    26400.75, 34999.00, 48200.00, 63750.60, 87300.00, 112500.00, 158400.00,
    245000.00, 396800.25, 540000.00, 1875000.00, 8400000.00,
]
BILL_MINS = [
    320.00, 500.00, 500.00, 650.00, 1000.00, 840.00, 1265.00, 1987.00,
    2640.00, 3499.00, 4820.00, 6375.00, 8730.00, 11250.00, 15840.00,
    24500.00, 39680.00, 54000.00, 187500.00, 840000.00,
]
PAYMENTS = [
    200.00, 650.75, 1890.00, 3400.00, 6125.50, 9800.00, 14300.00, 21560.25,
    29750.00, 37400.00, 55800.90, 74200.00, 98650.00, 134000.00, 187900.50,
    275400.00, 430000.00, 925000.00, 3680000.00, 12500000.00,
]


def indian(intstr):
    """Group digits South-Asian style: last 3, then pairs. 859665 -> 8,59,665"""
    if len(intstr) <= 3:
        return intstr
    last3, rest, parts = intstr[-3:], intstr[:-3], []
    while len(rest) > 2:
        parts.insert(0, rest[-2:])
        rest = rest[:-2]
    if rest:
        parts.insert(0, rest)
    return ",".join(parts + [last3])


def money(value, style):
    """Render a value with 2 decimals under a grouping style -> (raw, normalized)."""
    intpart = str(int(value))
    grouped = indian(intpart) if style == "indian" else "{:,}".format(int(intpart))
    raw = grouped + "." + "{:.2f}".format(value).split(".")[1]
    return raw, raw.replace(",", "")


class Lines:
    """Assemble a multi-line SMS while recording char offsets of tagged values."""

    def __init__(self):
        self.text = ""
        self.spans = {}

    def add(self, *chunks):
        """Each chunk is a literal str, or (key, value) to record a span for."""
        for ch in chunks:
            if isinstance(ch, str):
                self.text += ch
            else:
                key, val = ch
                self.spans[key] = (len(self.text), len(self.text) + len(val))
                self.text += val
        self.text += "\n"

    def done(self):
        return self.text.rstrip("\n"), self.spans


def span_obj(content, se):
    return {"text": content[se[0]:se[1]], "start": se[0], "end": se[1]}


def build():
    rnd = random.Random(20260916)
    rows = []
    mid = FIRST_ID

    def card():
        return f"{rnd.randint(100, 999)}***{rnd.randint(100, 999)}"

    def client_id():
        return str(rnd.randint(10**5, 10**8 - 1))

    def style(i):
        return "indian" if i % 2 == 0 else "western"

    # ---- format 1: purchase alert (expense) ----------------------------- #
    for i in range(20):
        # one grouping convention per message — a real sender never mixes them
        amt_raw, amt_norm = money(EXPENSE_AMOUNTS[i], style(i))
        bal_raw, bal_norm = money(EXPENSE_BALANCES[i], style(i))
        day = rnd.randint(1, 28)
        month = MONTHS[i % 12]
        year = 25 + (i % 3)
        ln = Lines()
        ln.add(f"{rnd.randint(0, 23):02d}:{rnd.randint(0, 59):02d} "
               f"{day:02d}-{month}-{year}")
        ln.add("BDT ", ("amt", amt_raw), f" purchased at {MERCHANTS[i]}")
        ln.add(f"CARD NO: {card()}")
        ln.add("Bal BDT ", ("bal", bal_raw))
        ln.add("CITY BANK")
        content, spans = ln.done()
        rows.append({
            "message_id": mid, "sender": "CITY_AMEX", "content": content,
            "category": "transaction", "type": "expense",
            "amount": amt_norm, "currency": "BDT", "balance": bal_norm,
            "amount_span": span_obj(content, spans["amt"]),
            "balance_span": span_obj(content, spans["bal"]),
            "currency_span": "BDT",
        })
        mid += 1

    # ---- format 2: statement (bill) ------------------------------------- #
    for i in range(20):
        st = style(i)
        due_raw, due_norm = money(BILL_TOTALS[i], st)
        min_raw, _ = money(BILL_MINS[i], st)
        month_idx = i % 12
        year = 25 + (i % 3)
        period = f"{MONTHS[month_idx]}'{year}"
        pay_m = (month_idx + 1) % 12 + 1
        pay_y = year + 1 if month_idx == 11 else year
        ln = Lines()
        ln.add("AMEX Bill ", ("period", period))
        ln.add("Total Due")
        ln.add("Tk ", ("due", due_raw))
        ln.add("Min Due")
        ln.add(f"Tk {min_raw}")
        ln.add(f"CARD: {card()}")
        ln.add(f"Client ID: {client_id()}")
        ln.add(f"Pay by {rnd.randint(1, 28):02d}-{pay_m:02d}-{pay_y}")
        slug = "".join(rnd.choice("abcdefghijklmnopqrstuvwxyz0123456789")
                       for _ in range(6))
        ln.add(f"eStatement:{SHORTENERS[i % len(SHORTENERS)]}/{slug}")
        content, spans = ln.done()
        rows.append({
            "message_id": mid, "sender": "CITY AMEX.", "content": content,
            "category": "bill", "total_due": due_norm, "currency": "BDT",
            "statement_month": month_idx + 1, "statement_year": 2000 + year,
            "total_due_span": span_obj(content, spans["due"]),
            "statement_span": span_obj(content, spans["period"]),
        })
        mid += 1

    # ---- format 3: bill payment received (transfer) --------------------- #
    for i in range(20):
        amt_raw, amt_norm = money(PAYMENTS[i], style(i + 1))
        day = rnd.randint(1, 28)
        month = MONTHS[(i + 5) % 12].upper()
        year = 25 + (i % 3)
        ln = Lines()
        ln.add(f"{day:02d}-{month}-{year}")
        ln.add("Tk. ", ("amt", amt_raw), " payment received")
        ln.add(f"CARD NO: {card()}")
        ln.add(f"Client ID: {client_id()}")
        content, spans = ln.done()
        rows.append({
            "message_id": mid, "sender": "CITY AMEX", "content": content,
            "category": "transaction", "type": "transfer",
            "amount": amt_norm, "currency": "BDT", "balance": None,
            "amount_span": span_obj(content, spans["amt"]),
            "balance_span": None, "currency_span": "Tk.",
        })
        mid += 1

    return rows


def validate(rows, existing_contents, existing_ids):
    for r in rows:
        c = r["content"]
        for key in ("amount_span", "balance_span", "total_due_span", "statement_span"):
            sp = r.get(key)
            if sp:
                assert c[sp["start"]:sp["end"]] == sp["text"], \
                    f"span mismatch {r['message_id']} {key}"
        if r["category"] == "transaction":
            assert r["amount"] == r["amount_span"]["text"].replace(",", "")
            if r["balance"] is not None:
                assert r["balance"] == r["balance_span"]["text"].replace(",", "")
        if r["category"] == "bill":
            assert r["total_due"] == r["total_due_span"]["text"].replace(",", "")
        assert c not in existing_contents, f"duplicate content {r['message_id']}"
        assert r["message_id"] not in existing_ids, f"duplicate id {r['message_id']}"
    assert len({r["content"] for r in rows}) == len(rows), "duplicate content within batch"


def main():
    existing = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]
    rows = build()
    validate(rows, {r["content"] for r in existing},
             {r["message_id"] for r in existing})

    if "--apply" not in sys.argv:
        for r in rows:
            print(f"--- {r['message_id']} {r['sender']} "
                  f"[{r.get('type') or r['category']}]")
            print(r["content"])
            print({k: v for k, v in r.items()
                   if k in ("amount", "balance", "total_due", "statement_month",
                            "statement_year")})
        print(f"\n{len(rows)} rows, spans validated. Re-run with --apply to append.")
        return

    with open(DATASET, "a", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")
    print(f"appended {len(rows)} rows to {DATASET}")


if __name__ == "__main__":
    main()
