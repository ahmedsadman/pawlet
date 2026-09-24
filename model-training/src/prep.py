"""Data prep helpers: NER label set + char-span -> subword-token BIO alignment.

The dataset stores entity spans as CHARACTER offsets (amount_span.start/end etc).
A transformer works on subword TOKENS, so we must project each char span onto the
token sequence using the fast tokenizer's offset_mapping. First token overlapping
a span -> B-<ENT>, following tokens -> I-<ENT>, everything else -> O, special
tokens -> -100 (ignored by the loss).
"""
from .config import NER_ENTITIES, MAX_LEN

NER_LABELS = ["O"] + [f"{p}-{e}" for e in NER_ENTITIES for p in ("B", "I")]
nlabel2id = {l: i for i, l in enumerate(NER_LABELS)}
nid2label = {i: l for l, i in nlabel2id.items()}

# dataset span key -> entity type
SPAN_KEYS = {
    "amount_span": "AMOUNT",
    "balance_span": "BALANCE",
    "total_due_span": "DUE",
    "statement_span": "PERIOD",
}


def record_spans(rec: dict):
    """Return [(start, end, ENT), ...] for every present span in a record."""
    out = []
    for key, ent in SPAN_KEYS.items():
        s = rec.get(key)
        if s:
            out.append((s["start"], s["end"], ent))
    return out


def align(text: str, spans, tok):
    """Tokenize `text` and produce token-level BIO label ids aligned to `spans`."""
    enc = tok(
        text,
        truncation=True,
        max_length=MAX_LEN,
        return_offsets_mapping=True,
    )
    labels = []
    started = set()  # span indices already opened with a B- tag
    for (st, en) in enc["offset_mapping"]:
        if st == en:  # special token ([CLS]/[SEP]/pad)
            labels.append(-100)
            continue
        lab = "O"
        for i, (a, b, ent) in enumerate(spans):
            if st < b and en > a:  # token overlaps this span
                lab = ("B-" if i not in started else "I-") + ent
                started.add(i)
                break
        labels.append(nlabel2id[lab])
    enc.pop("offset_mapping")
    enc["labels"] = labels
    return enc
