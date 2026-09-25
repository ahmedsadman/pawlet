"""Run the trained FUSED model on a raw SMS — classify + extract fields.

Usage:
  python -m src.predict "Your A/C debited by Tk 500. Balance Tk 1,200."
  python -m src.predict            # interactive: type a message, press Enter

Loads models/fused (train it first with `python -m src.train_fused`). One model,
one forward pass yields both the class logits and the per-token NER logits.
"""
import re
import sys
import torch

from .config import MODEL_DIR, MAX_LEN
from .model_fused import FusedModel
from transformers import AutoTokenizer

FUSED_DIR = MODEL_DIR / "fused"

_CUR = re.compile(r"(US\$|BDT|USD|Taka|taka|Tk\.?|TK|\$)", re.I)


def load():
    tok = AutoTokenizer.from_pretrained(FUSED_DIR)
    model = FusedModel.from_pretrained(FUSED_DIR).eval()
    # config maps come back from JSON with string keys — normalise to int.
    model._class_id2label = {int(k): v for k, v in model.config.class_id2label.items()}
    model._ner_id2label = {int(k): v for k, v in model.config.ner_id2label.items()}
    return tok, model


def classify(text, tok, model):
    enc = tok(text, truncation=True, max_length=MAX_LEN, return_tensors="pt")
    with torch.no_grad():
        probs = torch.softmax(model(**enc).class_logits[0], dim=-1)
    idx = int(probs.argmax())
    return model._class_id2label[idx], float(probs[idx])


def extract(text, tok, model):
    """Return entity spans, each with a confidence:
      conf = weakest token's softmax prob in the span (the weakest link — flags
             shaky boundaries / fragmentation that a mean would hide).
    """
    enc = tok(text, truncation=True, max_length=MAX_LEN,
              return_offsets_mapping=True, return_tensors="pt")
    offsets = enc.pop("offset_mapping")[0].tolist()
    with torch.no_grad():
        logits = model(**enc).ner_logits[0]
    probs = torch.softmax(logits, dim=-1)
    preds = logits.argmax(-1).tolist()
    tconf = probs.max(-1).values.tolist()  # prob of the chosen label per token
    id2label = model._ner_id2label

    def close(c):
        c["conf"] = min(c["_p"])  # weakest token = span confidence
        del c["_p"]
        spans.append(c)

    spans, cur = [], None
    for (st, en), pid, p in zip(offsets, preds, tconf):
        if st == en:  # special token
            continue
        lab = id2label[int(pid)]
        if lab == "O":
            if cur:
                close(cur); cur = None
            continue
        pre, ent = lab.split("-", 1)
        if pre == "B" or cur is None or cur["ent"] != ent:
            if cur:
                close(cur)
            cur = {"ent": ent, "start": st, "end": en, "_p": [p]}
        else:
            cur["end"] = en; cur["_p"].append(p)
    if cur:
        close(cur)
    for s in spans:
        s["text"] = text[s["start"]:s["end"]]
    return spans


def sniff_currency(text, span):
    """Heuristic: currency token nearest the amount span (model doesn't emit it)."""
    lo, hi = max(0, span["start"] - 8), min(len(text), span["end"] + 8)
    m = _CUR.search(text[lo:hi])
    return m.group(0) if m else None


def predict(text, models):
    tok, model = models
    label, conf = classify(text, tok, model)
    spans = extract(text, tok, model)

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
            print(f"       {s['ent']:<8} {s['text']!r}  (conf {s['conf']:.2f}){extra}")
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
