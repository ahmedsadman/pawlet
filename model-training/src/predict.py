"""Run the trained models on a raw SMS — classify + extract fields.

Usage:
  python -m src.predict "Your A/C debited by Tk 500. Balance Tk 1,200."
  python -m src.predict            # interactive: type a message, press Enter

Loads models/classifier and models/ner (must be trained first).
"""
import re
import sys
import torch
from transformers import (
    AutoTokenizer,
    AutoModelForSequenceClassification,
    AutoModelForTokenClassification,
)

from .config import MODEL_DIR, MAX_LEN

CLF_DIR = MODEL_DIR / "classifier"
NER_DIR = MODEL_DIR / "ner"

_CUR = re.compile(r"(US\$|BDT|USD|Taka|taka|Tk\.?|TK|\$)", re.I)


def load():
    ctok = AutoTokenizer.from_pretrained(CLF_DIR)
    cmodel = AutoModelForSequenceClassification.from_pretrained(CLF_DIR).eval()
    ntok = AutoTokenizer.from_pretrained(NER_DIR)
    nmodel = AutoModelForTokenClassification.from_pretrained(NER_DIR).eval()
    return ctok, cmodel, ntok, nmodel


def classify(text, tok, model):
    enc = tok(text, truncation=True, max_length=MAX_LEN, return_tensors="pt")
    with torch.no_grad():
        probs = torch.softmax(model(**enc).logits[0], dim=-1)
    idx = int(probs.argmax())
    return model.config.id2label[idx], float(probs[idx])


def extract(text, tok, model):
    enc = tok(text, truncation=True, max_length=MAX_LEN,
              return_offsets_mapping=True, return_tensors="pt")
    offsets = enc.pop("offset_mapping")[0].tolist()
    with torch.no_grad():
        preds = model(**enc).logits[0].argmax(-1).tolist()
    id2label = model.config.id2label

    spans, cur = [], None
    for (st, en), pid in zip(offsets, preds):
        if st == en:  # special token
            continue
        lab = id2label[int(pid)]
        if lab == "O":
            if cur:
                spans.append(cur); cur = None
            continue
        pre, ent = lab.split("-", 1)
        if pre == "B" or cur is None or cur["ent"] != ent:
            if cur:
                spans.append(cur)
            cur = {"ent": ent, "start": st, "end": en}
        else:
            cur["end"] = en
    if cur:
        spans.append(cur)
    for s in spans:
        s["text"] = text[s["start"]:s["end"]]
    return spans


def sniff_currency(text, span):
    """Heuristic: currency token nearest the amount span (model doesn't emit it)."""
    lo, hi = max(0, span["start"] - 8), min(len(text), span["end"] + 8)
    m = _CUR.search(text[lo:hi])
    return m.group(0) if m else None


def predict(text, models):
    ctok, cmodel, ntok, nmodel = models
    label, conf = classify(text, ctok, cmodel)
    spans = extract(text, ntok, nmodel)

    if label in ("income", "expense", "transfer"):
        cat = f"transaction / {label}"
    else:
        cat = label  # bill or null

    print(f"\nSMS: {text}")
    print(f"  -> class: {cat}   (confidence {conf:.2f})")
    if spans:
        print("  -> fields:")
        for s in spans:
            extra = ""
            if s["ent"] in ("AMOUNT", "BALANCE", "DUE"):
                c = sniff_currency(text, s)
                if c:
                    extra = f"   [currency ~ {c}]"
            print(f"       {s['ent']:<8} {s['text']!r}{extra}")
    else:
        print("  -> fields: (none)")


def main():
    models = load()
    if len(sys.argv) > 1:
        predict(" ".join(sys.argv[1:]), models)
        return
    print("Type an SMS and press Enter (Ctrl-D / Ctrl-C to quit):")
    try:
        for line in sys.stdin:
            line = line.strip()
            if line:
                predict(line, models)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
