"""Generate the synthetic (augmented) portion of the SMS training dataset.

The dataset (`data/sms-dataset-v1.jsonl`) mixes REAL bank SMS with SYNTHETIC
ones. Real rows carry `_source` of "real"/"manual"; synthetic rows are tagged
`_source="augmented"`. This script REGENERATES the augmented rows in place:

  1. read the existing dataset,
  2. keep the real rows (dedup identical content),
  3. generate fresh augmented rows until every leaf class has 150 total,
  4. validate spans, then overwrite the file.

Leaf classes: expense, income, transfer (transactions) + bill + null.

Each synthetic record is built from templates with slot placeholders. Money and
period slots are rendered by `render()`, which records the exact CHARACTER offset
of every extracted field so the NER spans are correct by construction.

Run from the project root:  python scripts/generate_dataset.py
"""
import json
import random
from collections import Counter

random.seed(42)  # deterministic: same seed -> same augmented data


# --------------------------------------------------------------------------- #
# Bank senders (made-up; real bank names are deliberately avoided so the model
# does not memorize a real bank's exact SMS format)
# --------------------------------------------------------------------------- #
BANK_NAMES = [
    "Meridian", "NorthPay", "BlueHarbor", "Zenith", "Crestline", "Unibank",
    "PolarPay", "SilverOak", "Trident", "Aurora", "Cascade", "Vertex",
    "Solaris", "EverGreen", "Ironwood", "Nimbus", "Kestrel", "Onyx", "Granite",
    "Sterling Oak", "Lumen", "Cobalt", "Marigold", "Harborstone", "Redwood",
]

# real names that must NEVER appear in augmented rows (asserted at the end)
REAL = [
    "city bank", "ebl", "mtb", "brac", "standard chartered", "dutch-bangla",
    "bkash", "nagad", "grameenphone", " gp", "scb",
]


def sender():
    """Random made-up bank sender string, with format variety.

    Example: sender() -> "ZENITH BANK"   (or "Cobalt Bank Ltd", "Onyx-BANK", ...)
    """
    n = random.choice(BANK_NAMES)
    return random.choice([
        f"{n} Bank", f"{n} Bank Ltd", f"{n.upper()} BANK", f"{n} Bank.",
        f"{n}-BANK", n.upper(), f"{n} Bank Limited",
    ])


# --------------------------------------------------------------------------- #
# Currency + number formatting
# --------------------------------------------------------------------------- #
BDT_TOK = ["Tk", "Tk.", "TK", "BDT", "Taka", "taka"]  # weighted in pick_money_style
USD_TOK = ["USD", "US$", "$"]
GLUE_OK = {"Tk", "Tk.", "TK", "$", "US$"}  # tokens that read fine glued to a number


def pick_money_style():
    """Randomly choose how one message renders money (currency + layout + digits).

    Returns a dict: iso ("BDT"/"USD"), token (raw currency text), layout
    (where the token sits vs the number), grp (digit grouping), dec (2 decimals?).

    Example: pick_money_style()
      -> {"iso":"BDT","token":"Tk","layout":"pre_space","grp":"western","dec":True}
         which later renders an amount like "Tk 8,000.00".
    """
    if random.random() < 0.72:
        iso = "BDT"
        token = random.choices(BDT_TOK, weights=[30, 10, 10, 25, 20, 5])[0]
    else:
        iso = "USD"
        token = random.choices(USD_TOK, weights=[6, 1, 3])[0]

    layout = random.choice(["pre_space", "pre_glue", "suffix_space", "suffix_glue"])
    grp = random.choice(["none", "western", "western", "indian"])
    dec = random.random() < 0.6
    return dict(iso=iso, token=token, layout=layout, grp=grp, dec=dec)


def indian(intstr):
    """Group an integer string in the South-Asian style (last 3, then pairs).

    Example: indian("859665") -> "8,59,665"
    """
    s = intstr
    if len(s) <= 3:
        return s
    last3, rest, parts = s[-3:], s[:-3], []
    while len(rest) > 2:
        parts.insert(0, rest[-2:])
        rest = rest[:-2]
    if rest:
        parts.insert(0, rest)
    return ",".join(parts + [last3])


def grpfmt(intstr, style):
    """Apply a digit-grouping style to an integer string.

    Examples:
      grpfmt("150000", "none")    -> "150000"
      grpfmt("150000", "western") -> "150,000"
      grpfmt("150000", "indian")  -> "1,50,000"
    """
    if style == "none":
        return intstr
    if style == "western":
        return "{:,}".format(int(intstr))
    return indian(intstr)


def money_raw(value, st):
    """Render a numeric value into (raw_text, normalized_text) per a money style.

    `raw` is what appears in the SMS (grouped, maybe with decimals). `normalized`
    is the label value: raw with commas stripped.

    Example: money_raw(8000.0, {"grp":"western","dec":True})
      -> ("8,000.00", "8000.00")
    """
    intpart = str(int(value))
    g = grpfmt(intpart, st["grp"])
    if st["dec"]:
        dec = "{:.2f}".format(value).split(".")[1]
        raw = g + "." + dec
    else:
        raw = g
    return raw, raw.replace(",", "")


# --------------------------------------------------------------------------- #
# Random context fragments (distractors: account/card numbers, dates, refs, ...)
# These carry digits the NER must learn to IGNORE.
# --------------------------------------------------------------------------- #
def acct():
    """Masked account-number fragment.  Example: acct() -> "A/C 12***3456" """
    return random.choice([
        f"***{random.randint(1000, 9999)}",
        f"{random.randint(10, 999)}***{random.randint(1000, 9999)}",
        f"A/C {random.randint(10, 99)}***{random.randint(1000, 9999)}",
    ])


def card():
    """Masked card number.  Example: card() -> "4988***3711" """
    return random.choice([
        f"{random.randint(4000, 4999)}**{random.randint(100, 999)}",
        f"{random.randint(400000, 499999)}**{random.randint(1000, 9999)}",
        f"{random.randint(4000, 4999)}***{random.randint(1000, 9999)}",
    ])


def last4():
    """Last-4 card digits.  Example: last4() -> "7788" """
    return f"{random.randint(1000, 9999)}"


def date():
    """Random 2026 date in a variety of formats.  Example: date() -> "15-Sep-26" """
    d = random.randint(1, 28)
    m = random.randint(1, 12)
    y = 2026
    ab = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
          "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"][m - 1]
    return random.choice([
        f"{d:02d}-{m:02d}-{y}", f"{d:02d}-{ab.title()}-26", f"{y}-{m:02d}-{d:02d}",
        f"{d:02d}/{m:02d}/{y}", f"{d} {ab.title()} {y}",
    ])


def tm():
    """Random time-of-day string.  Example: tm() -> "10:43 pm" """
    return random.choice(
        ["09:57:21 AM", "10:43 pm", "02:13:03 PM", "14:06", "08:46 pm", "11:59 AM"])


def ref():
    """Random transaction reference number.  Example: ref() -> "570284913" """
    return f"{random.randint(100000, 999999999)}"


def otp():
    """Random OTP code.  Example: otp() -> "912345" """
    return f"{random.randint(1000, 999999)}"


MERCH = [
    "Foodpanda", "Daraz", "Amazon", "Uber", "Pathao", "Shwapno", "Agora",
    "Star Kabab", "Netflix", "Spotify", "Steadfast", "City Grocers",
    "Cloud Hosting", "Careem", "AliExpress", "Meena Bazar", "Chaldal",
]
CH = ["BEFTN", "NPSB", "RTGS", "internet banking", "mobile app",
      "branch deposit", "ATM", "IBFT"]
LOC = ["Gulshan", "Dhanmondi", "Banani", "Uttara", "Mirpur", "Motijheel",
       "Agrabad", "Bashundhara"]


def merch():
    """Random merchant name.  Example: merch() -> "Daraz" """
    return random.choice(MERCH)


def chan():
    """Random funding channel.  Example: chan() -> "NPSB" """
    return random.choice(CH)


def loc():
    """Random location/branch.  Example: loc() -> "Gulshan" """
    return random.choice(LOC)


def period():
    """Random statement period (for bills), in many formats, plus parsed ints.

    Example: period() -> {"raw":"AUG 2026", "month":8, "year":2026}
    """
    m = random.randint(1, 12)
    y = 2026
    ab = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
          "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"][m - 1]
    full = ["January", "February", "March", "April", "May", "June", "July",
            "August", "September", "October", "November", "December"][m - 1]
    raw = random.choice([
        f"{ab} {y}", f"{ab}{y}", f"{ab.title()} {y}", f"{full} {y}",
        f"{m:02d}/{y}", f"{m:02d}-{y}", f"{y}-{m:02d}", f"{y} {ab}",
        f"{y} {ab.title()}", f"{m:02d}.{y}", f"{y}.{m:02d}",
    ])
    return dict(raw=raw, month=m, year=y)


# --------------------------------------------------------------------------- #
# Template renderer
# --------------------------------------------------------------------------- #
def render(parts, st, values):
    """Assemble a message from template `parts`, recording field char-offsets.

    `parts` is a list where each item is either a literal string, or a marker
    tuple: ("amt",) / ("bal",) / ("due",) / ("min",) / ("period",). Money markers
    are rendered using the style `st` (token placement); the number substring's
    offset is stored in `spans` for AMOUNT/BALANCE/DUE (and the raw period text
    for PERIOD). "min" (bill minimum-due) is rendered but NOT tracked — it is a
    deliberate NER distractor.

    Returns (content, spans) where spans maps field -> (start, end).

    Example:
      render(["Bal ", ("bal",), "."],
             {"token":"Tk","layout":"pre_space"},
             {"bal":"1,200"})
      -> ("Bal Tk 1,200.", {"bal": (7, 12)})   # content[7:12] == "1,200"
    """
    out = ""
    spans = {}
    for p in parts:
        if isinstance(p, str):
            out += p
            continue

        kind = p[0]
        if kind == "period":
            v = values["period"]["raw"]
            spans["statement"] = (len(out), len(out) + len(v))
            out += v
            continue

        raw = values[kind]  # raw numeric string
        tok, lay = st["token"], st["layout"]
        if lay == "pre_space":
            seq = [("lit", tok + " "), ("num", raw)]
        elif lay == "pre_glue":
            seq = [("lit", tok), ("num", raw)]
        elif lay == "suffix_glue":
            seq = [("num", raw), ("lit", tok)]
        else:  # suffix_space
            seq = [("num", raw), ("lit", " " + tok)]

        for typ, v in seq:
            if typ == "lit":
                out += v
            else:
                if kind in ("amt", "bal", "due"):
                    spans[kind] = (len(out), len(out) + len(v))
                out += v
    return out, spans


def span_obj(content, se):
    """Turn a (start, end) offset into the dataset's span object.

    Example: span_obj("Bal 1,200.", (4, 9)) -> {"text":"1,200","start":4,"end":9}
    """
    return {"text": content[se[0]:se[1]], "start": se[0], "end": se[1]}


# monotonic id source for augmented rows (reset before generation, see rebuild())
MID = [100001]


def nid():
    """Return the next unique augmented message_id.  Example: nid() -> 200001 """
    v = MID[0]
    MID[0] += 1
    return v


# --------------------------------------------------------------------------- #
# Record generators (one per record shape)
# --------------------------------------------------------------------------- #
def gen_txn(kind):
    """Build one transaction record for kind in {expense, income, transfer}.

    Picks a money style + amount (+ optional balance), fills a random template
    for that kind, and returns a dataset record with correct amount/balance spans.
    ~30% of records use round-thousand western numbers (e.g. "150,000") so the
    NER learns full comma-grouped spans. A closing "Thank you" is appended to ~35%
    of records of EVERY kind so politeness is not a transfer-only signal.

    Example (abridged): gen_txn("expense") ->
      {"content":"... debited by Tk 9,500. Balance: Tk 150,000.",
       "type":"expense","amount":"9500","balance":"150000",
       "amount_span":{"text":"9,500",...}, "balance_span":{"text":"150,000",...},
       "currency":"BDT","currency_span":"Tk", ...}
    """
    st = pick_money_style()

    # amount range depends on kind + currency
    if kind == "expense":
        lo, hi = (50, 200000) if st["iso"] == "BDT" else (5, 2000)
    else:
        lo, hi = (100, 300000) if st["iso"] == "BDT" else (5, 3000)

    amt_v = round(random.uniform(lo, hi), 2) if st["dec"] else float(random.randint(int(lo), int(hi)))
    amt_raw, amt_norm = money_raw(amt_v, st)

    # transfers rarely quote a balance; expense/income usually do
    has_bal = (random.random() < 0.85) if kind != "transfer" else (random.random() < 0.3)
    bal_v = round(random.uniform(1000, 2000000), 2) if st["dec"] else float(random.randint(1000, 2000000))
    bal_raw, bal_norm = money_raw(bal_v, st)

    # ~30%: round-thousand western grouping so NER sees full spans like "150,000"
    if random.random() < 0.30:
        st["grp"], st["dec"] = "western", False
        amt_v = float(max(1000, round(amt_v / 1000) * 1000))
        bal_v = float(max(1000, round(bal_v / 1000) * 1000))
        amt_raw, amt_norm = money_raw(amt_v, st)
        bal_raw, bal_norm = money_raw(bal_v, st)

    values = {"amt": amt_raw, "bal": bal_raw}
    ctx = dict(
        a=acct(), c=card(), l4=last4(), d=date(), t=tm(), m=merch(),
        ch=chan(), lo=loc(), r=ref(),
        an=f"{random.randint(1000, 9999)}***{random.randint(1000, 9999)}",
    )
    P_amt, P_bal = ("amt",), ("bal",)

    if kind == "expense":
        tpls = [
            [f"{ctx['a']} debited by ", P_amt, f" on {ctx['d']}."] + ([" Available balance ", P_bal, "."] if has_bal else []),
            ["Purchase of ", P_amt, f" at {ctx['m']} on {ctx['d']}."] + ([" Bal ", P_bal, "."] if has_bal else []),
            [P_amt, f" withdrawn from ATM {ctx['lo']} on {ctx['d']}."] + ([" C/B ", P_bal, "."] if has_bal else []),
            ["Debit alert: ", P_amt, f" spent at {ctx['m']}. Ref {ctx['r']}."] + ([" New balance ", P_bal, "."] if has_bal else []),
            [f"Your card ending {ctx['l4']} used for ", P_amt, f" at {ctx['m']} on {ctx['d']} {ctx['t']}."] + ([" Balance: ", P_bal, "."] if has_bal else []),
            ["Payment of ", P_amt, f" done from {ctx['a']}."] + ([" Remaining balance ", P_bal, "."] if has_bal else []),
            [f"{ctx['m']} charged your account ", P_amt, f". Txn ref {ctx['r']} on {ctx['d']}."] + ([" Balance now ", P_bal, "."] if has_bal else []),
            # formal styles (real inboxes phrase debits this way)
            [f"Dear Sir, your account {ctx['an']} got debited by ", P_amt, f" on {ctx['d']}."] + ([" Balance: ", P_bal, "."] if has_bal else []),
            [f"Dear Customer, your account {ctx['an']} has been debited by ", P_amt, "."] + ([" Available Balance: ", P_bal, "."] if has_bal else []),
        ]
    elif kind == "income":
        tpls = [
            [f"{ctx['a']} credited by ", P_amt, f" ({ctx['ch']}) on {ctx['d']}."] + ([" C/B ", P_bal, "."] if has_bal else []),
            ["You have received ", P_amt, f" in your account {ctx['a']} on {ctx['d']}."] + ([" Avbl Bal ", P_bal, "."] if has_bal else []),
            ["Salary of ", P_amt, f" deposited to {ctx['a']}."] + ([" Balance: ", P_bal, "."] if has_bal else []),
            ["Refund of ", P_amt, f" credited to your card ending {ctx['l4']}."] + ([" Bal ", P_bal, "."] if has_bal else []),
            [P_amt, f" deposited via {ctx['ch']} on {ctx['d']}."] + ([" Current balance ", P_bal, "."] if has_bal else []),
            ["Great news! ", P_amt, f" has landed in {ctx['a']} on {ctx['d']}."] + ([" Balance now ", P_bal, "."] if has_bal else []),
            ["Fund transfer of ", P_amt, f" received in {ctx['a']}. Ref {ctx['r']}."] + ([" Balance ", P_bal, "."] if has_bal else []),
            # formal styles (real inboxes phrase credits this way)
            [f"Dear Sir, your account {ctx['an']} got credited by ", P_amt, f" on {ctx['d']}."] + ([" Balance: ", P_bal, "."] if has_bal else []),
            [f"Dear Customer, your account {ctx['an']} has been credited by ", P_amt, "."] + ([" Available Balance: ", P_bal, "."] if has_bal else []),
        ]
    else:  # transfer = credit-card bill payment received by the issuer
        tpls = [
            ["Payment of ", P_amt, f" received for your card ending {ctx['l4']}. Outstanding: 0.00"],
            ["Payment of ", P_amt, f" credited to Card {ctx['c']} on {ctx['d']} {ctx['t']}."],
            ["Card payment confirmed: ", P_amt, f" received for card {ctx['c']}."],
            ["We have received your credit card payment of ", P_amt, f". Card {ctx['c']} on {ctx['d']}."],
            [P_amt, f" paid towards your card {ctx['c']} bill. Due now 0.00"] + ([" Balance ", P_bal, "."] if has_bal else []),
            [f"Your card {ctx['c']} bill payment of ", P_amt, " is successful."] + ([" Balance ", P_bal, "."] if has_bal else []),
            [f"Payment received on card {ctx['c']}: ", P_amt, f". Statement cleared. Ref {ctx['r']}."],
        ]

    parts = random.choice(tpls)
    # spread a closing "thank you" across ALL classes so it is not a transfer-only cue
    if random.random() < 0.35:
        parts = parts + [random.choice([" Thank you.", " Thank You.", " Thanks."])]

    content, spans = render(parts, st, values)
    bal_present = "bal" in spans
    return {
        "message_id": nid(),
        "sender": sender(),
        "content": content,
        "category": "transaction",
        "type": kind,
        "amount": amt_norm,
        "currency": st["iso"],
        "balance": (bal_norm if bal_present else None),
        "_server_type": None,
        "_relabeled": False,
        "amount_span": span_obj(content, spans["amt"]),
        "balance_span": span_obj(content, spans["bal"]) if bal_present else None,
        "currency_span": st["token"],
        "_source": "augmented",
    }


def gen_bill():
    """Build one credit-card statement (bill) record.

    Has a total-due span + a statement-period span; the minimum-due is rendered
    as an untracked distractor.

    Example (abridged): gen_bill() ->
      {"content":"Statement AUG 2026: outstanding Tk 4,111.79. Minimum payment Tk 500 ...",
       "category":"bill","total_due":"4111.79","currency":"BDT",
       "statement_month":8,"statement_year":2026,
       "total_due_span":{"text":"4,111.79",...},"statement_span":{"text":"AUG 2026",...}}
    """
    st = pick_money_style()
    tot_v = round(random.uniform(500, 90000), 2) if st["dec"] else float(random.randint(500, 90000))
    tot_raw, tot_norm = money_raw(tot_v, st)
    min_v = float(random.randint(100, 2000))
    min_raw, _ = money_raw(min_v, dict(grp=st["grp"], dec=False))

    per = period()
    ctx = dict(c=card(), d=date())
    values = {"due": tot_raw, "min": min_raw, "period": per}
    P_due, P_min, P_per = ("due",), ("min",), ("period",)
    has_min = random.random() < 0.8

    tpls = [
        [f"Your credit card {ctx['c']} statement for ", P_per, ". Total due ", P_due, "."] + ([" Min due ", P_min, f". Pay by {ctx['d']}."] if has_min else []),
        [f"Bill generated for card {ctx['c']} ", P_per, ". Total Due: ", P_due] + ([", Min Due: ", P_min, "."] if has_min else ["."]),
        ["Statement ", P_per, ": outstanding ", P_due, "."] + ([" Minimum payment ", P_min, f" due {ctx['d']}."] if has_min else []),
        ["Dear customer, your ", P_per, " card bill is ", P_due, "."] + ([" Minimum ", P_min, "."] if has_min else []),
        [f"Card {ctx['c']}: ", P_due, " total due for ", P_per, "."] + ([" ", P_min, f" min due by {ctx['d']}."] if has_min else []),
    ]

    parts = random.choice(tpls)
    content, spans = render(parts, st, values)
    return {
        "message_id": nid(),
        "sender": sender(),
        "content": content,
        "category": "bill",
        "total_due": tot_norm,
        "currency": st["iso"],
        "statement_month": per["month"],
        "statement_year": per["year"],
        "total_due_span": span_obj(content, spans["due"]),
        "statement_span": span_obj(content, spans["statement"]),
        "_source": "augmented",
    }


def money_inline(st=None):
    """Render a standalone money string (for null messages; no span tracked).

    Example: money_inline() -> "Tk 45,300"   (currency + amount, random layout)
    """
    st = st or pick_money_style()
    v = round(random.uniform(50, 500000), 2) if st["dec"] else float(random.randint(50, 500000))
    raw, _ = money_raw(v, st)
    tok, lay = st["token"], st["layout"]
    if lay == "pre_space":
        return f"{tok} {raw}"
    if lay == "pre_glue":
        return f"{tok}{raw}"
    if lay == "suffix_glue":
        return f"{raw}{tok}"
    return f"{raw} {tok}"


def promo_money():
    """Like money_inline but ROUND, realistic promo figures (no odd decimals).

    Example: promo_money() -> "Tk 100,000"   (or "USD 5,000", ...)
    """
    st = pick_money_style()
    st["dec"] = False
    st["grp"] = random.choice(["western", "none"])
    if st["iso"] == "USD":
        v = float(random.choice([500, 1000, 2000, 5000, 10000, 20000, 50000]))
    else:
        v = float(random.choice([5000, 10000, 20000, 25000, 50000, 100000,
                                 200000, 500000, 1000000, 2000000]))
    raw, _ = money_raw(v, st)
    tok, lay = st["token"], st["layout"]
    if lay == "pre_space":
        return f"{tok} {raw}"
    if lay == "pre_glue":
        return f"{tok}{raw}"
    if lay == "suffix_glue":
        return f"{raw}{tok}"
    return f"{raw} {tok}"


def gen_null(kind):
    """Build one non-transaction / non-bill message (category null, no spans).

    `kind` selects the flavor of negative example:
      balance_only, promo_amount, promo_plain, statement_ready, otp_amount,
      otp_generic, security, min_due_reminder.
    Several kinds deliberately CONTAIN numbers/currency (balance-only notices,
    promos, OTP-with-amount) so the model learns that "has a number" does not
    mean "transaction".

    Example: gen_null("otp_generic") ->
      {"content":"418290 is your one time password (OTP). ...",
       "category":None,"_server_subtype":"otp_generic","_source":"augmented"}
    """
    c = card()
    d = date()
    o = otp()
    per = period()["raw"]
    m = money_inline()
    pm = promo_money()

    if kind == "balance_only":
        content = random.choice([
            f"Your A/C {acct()} available balance is {m} as on {d}. Thank you for banking with us.",
            f"Balance enquiry: {acct()} current balance {m}. No recent transaction.",
            f"As requested, your account balance is {m} on {d}.",
        ])
    elif kind == "promo_amount":
        content = random.choice([
            f"Enjoy 0% EMI up to {pm} on your credit card {c}. Offer valid till {d}.",
            f"Get a personal loan up to {pm} at low interest. Apply on the app today!",
            f"Spend {pm} this month and earn 2x reward points. T&C apply.",
        ])
    elif kind == "promo_plain":
        cw = random.choice(["USD", "BDT"])
        pct = random.choice([10, 15, 20, 25, 30, 50])
        vt = date()
        content = random.choice([
            f"Open a {cw} savings account today and enjoy zero maintenance fees. Visit your nearest branch.",
            f"Introducing our new {cw} platinum card. Apply now on the app and skip the annual fee!",
            f"Travel smart with our {cw} prepaid card. Zero issuance fee till {vt}.",
            f"Now shop worldwide with our {cw} international card. Apply today at any branch.",
            f"Get {pct}% off at 500+ partner outlets when you pay with your card. Offer till {vt}.",
            f"Enjoy up to {pct}% discount at partner restaurants this month. T&C apply.",
            "Eid Mubarak from all of us! Wishing you peace and prosperity this festive season.",
            "Download our mobile app for faster, safer banking. Available now on all app stores.",
            "Refer a friend and both earn reward points. Start referring on the app today!",
            f"Our {loc()} branch is now open on Saturdays from 10am. Visit for all your banking needs.",
            f"Upgrade to premium banking and enjoy priority service at our {loc()} branch.",
        ])
    elif kind == "statement_ready":
        content = random.choice([
            f"Your card {c} statement for {per} is ready. View it in the mobile app.",
            f"Statement notice: your {per} e-statement has been emailed. No action needed.",
            f"Dear customer, your monthly statement for {per} is now available online.",
        ])
    elif kind == "otp_amount":
        content = random.choice([
            f"For {m} transaction at {merch()}, OTP is {o} for Card {c}. Expires in 2 minutes. Do not share.",
            f"Your OTP for a {m} purchase at {merch()} is {o}. Valid 3 minutes.",
            f"OTP {o} to authorize {m} payment to {merch()}. Never share your OTP.",
        ])
    elif kind == "otp_generic":
        content = random.choice([
            f"{o} is your one time password (OTP). Valid for 2 minutes. Do not share with anyone.",
            f"Use OTP {o} to log in to your banking app. Valid 3 minutes.",
            f"{o} is your OTP to enroll card {c} for online transaction. DO NOT SHARE.",
        ])
    elif kind == "security":
        hl = f"{random.randint(10000, 99999)}"
        content = random.choice([
            f"Never share your card number, OTP, PIN, CVV or password with anyone. Stay safe. Helpline {hl}.",
            f"Security alert: a new device logged in to your account on {d}. If not you, call {hl}.",
            f"Beware of fraud. Bank staff will never ask for your PIN or OTP. Report to {hl}.",
            f"We noticed a login from {loc()} on {d}. If this was not you, contact {hl} immediately.",
        ])
    else:  # min_due_reminder (borderline null: mentions an amount, but is a reminder)
        content = random.choice([
            f"Reminder: please pay your card {c} minimum due of {m} to avoid late charges. Ignore if already paid.",
            f"Dear customer, your credit card payment is pending. Pay {m} at the earliest. If paid, ignore.",
            f"Gentle reminder to clear your outstanding of {m} on card {c}. Thank you.",
        ])

    return {
        "message_id": nid(),
        "sender": sender(),
        "content": content,
        "category": None,
        "_server_subtype": kind,
        "_relabeled": False,
        "_source": "augmented",
    }


# --------------------------------------------------------------------------- #
# Rebuild driver
# --------------------------------------------------------------------------- #
def leaf(r):
    """Leaf class of a record: bill / null / <transaction type>.

    Example: leaf({"category":"transaction","type":"income"}) -> "income"
    """
    if r.get("category") == "bill":
        return "bill"
    if r.get("category") is None:
        return "null"
    return r.get("type")


def rebuild(path="data/sms-dataset-v1.jsonl", target=150):
    """Regenerate the augmented rows in `path` so every leaf class has `target`.

    Keeps real rows (dedup identical content), then generates unique augmented
    rows until each class reaches `target`. Validates every span (content slice
    must equal the stored text) and that normalized values match the comma-
    stripped span, then overwrites the file. Prints a summary.
    """
    existing = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]

    # keep real/manual rows, dedup by content (prefer real over augmented, low id)
    real = [r for r in existing if r.get("_source") != "augmented"]
    real.sort(key=lambda r: (0 if r.get("_source") in (None, "real", "manual") else 1,
                             r["message_id"]))
    seen, kept, dropped = set(), [], []
    for r in real:
        if r["content"] in seen:
            dropped.append(r["message_id"])
            continue
        seen.add(r["content"])
        kept.append(r)

    have = Counter(leaf(r) for r in kept)
    print("real kept:", len(kept), " dropped real dups:", dropped, " have:", dict(have))

    MID[0] = 200001  # augmented id range, no collision with real ids
    new = []

    def fill(genfn, cls, need):
        """Generate `need` unique records of class `cls` via `genfn`."""
        made = tries = 0
        while made < need:
            tries += 1
            if tries > need * 80:
                raise RuntimeError("cannot fill " + cls)
            r = genfn()
            if leaf(r) != cls or r["content"] in seen:
                continue
            seen.add(r["content"])
            new.append(r)
            made += 1

    for cls in ["expense", "income", "transfer"]:
        fill(lambda c=cls: gen_txn(c), cls, target - have.get(cls, 0))
    fill(gen_bill, "bill", target - have.get("bill", 0))

    # null: cycle through subtypes to reach the target
    nk = ["balance_only", "promo_amount", "promo_plain", "otp_amount",
          "otp_generic", "statement_ready", "security", "min_due_reminder"]
    need = target - have.get("null", 0)
    i = made = tries = 0
    while made < need:
        tries += 1
        if tries > need * 120:
            raise RuntimeError("cannot fill null")
        r = gen_null(nk[i % len(nk)])
        if r["content"] in seen:
            continue
        seen.add(r["content"])
        new.append(r)
        made += 1
        i += 1

    allr = kept + new

    # --- validation ---
    bad = 0
    for r in allr:
        c = r["content"]
        low = c.lower()
        assert not any(rb in low for rb in REAL) or r.get("_source") != "augmented", \
            f"real bank name leaked into augmented row {r['message_id']}"
        for k in ("amount_span", "balance_span", "total_due_span", "statement_span"):
            sp = r.get(k)
            if sp and c[sp["start"]:sp["end"]] != sp["text"]:
                bad += 1
        if r.get("category") == "transaction":
            assert r["amount"] == r["amount_span"]["text"].replace(",", "")
            if r["balance"] is not None:
                assert r["balance"] == r["balance_span"]["text"].replace(",", "")
        if r.get("category") == "bill":
            assert r["total_due"] == r["total_due_span"]["text"].replace(",", "")
    assert bad == 0, f"{bad} span mismatches"

    ids = [r["message_id"] for r in allr]
    assert len(ids) == len(set(ids)), "duplicate message_id"
    cont = [r["content"] for r in allr]
    assert len(cont) == len(set(cont)), "duplicate content remains"

    with open(path, "w", encoding="utf-8") as f:
        for r in allr:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print("TOTAL:", len(allr),
          " by leaf:", dict(Counter(leaf(r) for r in allr)),
          " aug:", sum(1 for r in allr if r.get("_source") == "augmented"),
          " uniq content:", len(set(cont)))


if __name__ == "__main__":
    rebuild()
