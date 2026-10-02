"""Evaluate the trained fused model on a split — no retraining.

Loads models/fused, runs it over data/splits/<split>.jsonl, and prints:
  1. classification report (per-class precision/recall/F1)
  2. NER report (seqeval, per-entity)
  3. per-record table: gold vs predicted, class + NER PASS/FAIL

Usage:
  python -m src.evaluate            # default split: test
  python -m src.evaluate val
"""
import json
import sys
import torch
from sklearn.metrics import classification_report as clf_report
from seqeval.metrics import classification_report as seq_report

from .config import SPLIT_DIR, MAX_LEN, CLASS_LABELS, leaf_label
from .prep import record_spans
from .predict import load, classify, extract


def ner_token_labels(rec, tok, model):
    """Gold + predicted BIO tag sequences for one record (special tokens dropped)."""
    text = rec["content"]
    enc = tok(text, truncation=True, max_length=MAX_LEN,
              return_offsets_mapping=True, return_tensors="pt")
    offsets = enc.pop("offset_mapping")[0].tolist()
    with torch.no_grad():
        pred_ids = model(**enc).ner_logits[0].argmax(-1).tolist()
    spans = record_spans(rec)
    gold, pred, started = [], [], set()
    for (st, en), pid in zip(offsets, pred_ids):
        if st == en:  # special token
            continue
        lab = "O"
        for i, (a, b, ent) in enumerate(spans):
            if st < b and en > a:  # token overlaps span
                lab = ("B-" if i not in started else "I-") + ent
                started.add(i)
                break
        gold.append(lab)
        pred.append(model._ner_id2label[int(pid)])
    return gold, pred


def gold_entities(rec):
    """Gold {(ENT, text)} set from the record's char spans."""
    text = rec["content"]
    return {(ent, text[a:b]) for (a, b, ent) in record_spans(rec)}


def main():
    split = sys.argv[1] if len(sys.argv) > 1 else "test"
    path = SPLIT_DIR / f"{split}.jsonl"
    if not path.exists():
        sys.exit(f"no split at {path} — run `python -m src.split` first")

    rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    tok, model = load()

    y_true, y_pred = [], []
    gold_seqs, pred_seqs = [], []
    table = []

    for rec in rows:
        text = rec["content"]
        gold_c = leaf_label(rec)
        pred_c, conf = classify(text, tok, model)
        y_true.append(gold_c)
        y_pred.append(pred_c)

        g_seq, p_seq = ner_token_labels(rec, tok, model)
        gold_seqs.append(g_seq)
        pred_seqs.append(p_seq)

        spans = extract(text, tok, model)
        ge = gold_entities(rec)
        pe = {(s["ent"], s["text"]) for s in spans}
        ner_conf = min((s["conf"] for s in spans), default=None)  # weakest entity
        table.append({
            "id": rec.get("message_id", "?"),
            "gold_c": gold_c,
            "pred_c": pred_c,
            "conf": conf,
            "class_ok": gold_c == pred_c,
            "ner_ok": ge == pe,
            "ner_conf": ner_conf,
            "gold_e": ge,
            "spans": spans,
            "content": text.replace("\n", " "),
        })

    print(f"\n===== split: {split}  ({len(rows)} records) =====\n")

    print("----- CLASSIFICATION (per-class) -----")
    print(clf_report(y_true, y_pred, labels=CLASS_LABELS, zero_division=0))

    print("----- NER (seqeval, per-entity) -----")
    print(seq_report(gold_seqs, pred_seqs, zero_division=0))

    class_ok = sum(r["class_ok"] for r in table)
    ner_ok = sum(r["ner_ok"] for r in table)
    n = len(table)
    print("----- PER-RECORD -----")
    print(f"class exact: {class_ok}/{n} ({class_ok / n:.1%})    "
          f"NER exact: {ner_ok}/{n} ({ner_ok / n:.1%})\n")

    hdr = (f"{'ID':>8}  {'GOLD->PRED':<20} {'CONF':>5} {'CLS':<4} "
           f"{'NER':<4} {'NERc':>5} CONTENT")
    print(hdr)
    print("-" * len(hdr))
    for r in sorted(table, key=lambda x: (x["class_ok"] and x["ner_ok"])):
        idc = str(r["id"])
        arrow = f"{r['gold_c']}->{r['pred_c']}"
        cls = "ok" if r["class_ok"] else "FAIL"
        ner = "ok" if r["ner_ok"] else "FAIL"
        nc = f"{r['ner_conf']:.2f}" if r["ner_conf"] is not None else "  -"
        print(f"{idc:>8}  {arrow:<20} {r['conf']:>5.2f} {cls:<4} "
              f"{ner:<4} {nc:>5} {r['content']}")

    # show entity diffs for the NER failures (most useful debugging bit)
    fails = [r for r in table if not r["ner_ok"]]
    if fails:
        print("\n----- NER mismatches (gold vs pred entities) -----")
        for r in fails:
            print(f"  [{r['id']}] {r['content']}")
            print(f"       gold: {sorted(r['gold_e'])}")
            pred = ", ".join(
                f"{s['ent']}:{s['text']!r}@{s['conf']:.2f}"
                for s in sorted(r["spans"], key=lambda s: (s["ent"], s["start"]))
            )
            print(f"       pred: {pred or '(none)'}")


if __name__ == "__main__":
    main()
