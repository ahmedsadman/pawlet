"""Data prep helpers: NER label set + char-span -> subword-token BIO alignment.

The dataset stores entity spans as CHARACTER offsets (amount_span.start/end etc).
A transformer works on subword TOKENS, so we must project each char span onto the
token sequence using the fast tokenizer's offset_mapping. First token overlapping
a span -> B-<ENT>, following tokens -> I-<ENT>, everything else -> O, special
tokens -> -100 (ignored by the loss).
"""
from .config import NER_ENTITIES, MAX_LEN, CLASS_LABELS, leaf_label

NER_LABELS = ["O"] + [f"{p}-{e}" for e in NER_ENTITIES for p in ("B", "I")]
nlabel2id = {l: i for i, l in enumerate(NER_LABELS)}
nid2label = {i: l for l, i in nlabel2id.items()}

# classification label maps (mirror of train_* scripts; shared here so the fused
# feature builder can emit the class id alongside the NER tags).
clabel2id = {l: i for i, l in enumerate(CLASS_LABELS)}
cid2label = {i: l for l, i in clabel2id.items()}

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


def _bio_ids(offsets, spans):
    """Project char `spans` onto token `offsets`, return BIO label ids.

    First token overlapping a span -> B-<ENT>, following tokens -> I-<ENT>,
    non-overlapping -> O, special tokens (start==end) -> -100 (ignored by loss).
    """
    labels = []
    started = set()  # span indices already opened with a B- tag
    for (st, en) in offsets:
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
    return labels


def align(text: str, spans, tok):
    """Tokenize `text` and produce token-level BIO label ids aligned to `spans`."""
    enc = tok(
        text,
        truncation=True,
        max_length=MAX_LEN,
        return_offsets_mapping=True,
    )
    enc["labels"] = _bio_ids(enc.pop("offset_mapping"), spans)
    return enc


def fused_features(rec: dict, tok):
    """Build one multi-task training example from a dataset record.

    Emits input_ids, attention_mask, (token_type_ids if the tokenizer produces
    them), `class_labels` (scalar class id) and `ner_labels` (token BIO ids).
    Label keys are deliberately NOT `labels` — HF Trainer treats `labels`
    specially, which collides with a two-head model.
    """
    enc = tok(
        rec["content"],
        truncation=True,
        max_length=MAX_LEN,
        return_offsets_mapping=True,
    )
    enc["ner_labels"] = _bio_ids(enc.pop("offset_mapping"), record_spans(rec))
    enc["class_labels"] = clabel2id[leaf_label(rec)]
    return enc
