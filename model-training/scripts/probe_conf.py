"""Per-class NER confidence probe for a fused model dir — measures how many rows
would clear the on-device gate (weakest NER span conf >= 0.90), which is what
decides local-parse vs LLM fallback. Also runs a fixed EBL-novel-card bill probe.

Usage:  python -m scripts.probe_conf models/fused test
"""
import sys
from pathlib import Path
from collections import defaultdict
import json

from src import predict
from src.config import SPLIT_DIR, leaf_label

GATE = 0.90
PROBE = ("Monthly bill 404055******1111 DEC2026; Total Due: BDT 5000.00, "
         "Min Due: BDT 500.00, Last Pmt: 20-DEC-26. "
         "Statement link https://onelink.to/eblskybanking")


def main():
    model_dir = sys.argv[1]
    split = sys.argv[2] if len(sys.argv) > 2 else "test"
    predict.FUSED_DIR = Path(model_dir)
    tok, model = predict.load()

    rows = [json.loads(l) for l in open(SPLIT_DIR / f"{split}.jsonl", encoding="utf-8") if l.strip()]
    agg = defaultdict(lambda: {"n": 0, "pass": 0, "sum": 0.0})
    for r in rows:
        spans = predict.extract(r["content"], tok, model)
        if not spans:
            continue
        nerc = min(s["conf"] for s in spans)
        g = leaf_label(r)
        a = agg[g]
        a["n"] += 1
        a["sum"] += nerc
        a["pass"] += int(nerc >= GATE)

    print(f"\n### {model_dir}  split={split}  (gate NERc>={GATE})")
    print(f"{'class':10} {'n':>3} {'mean_NERc':>9} {'>=gate':>8} {'pass%':>6}")
    for g in ("expense", "income", "transfer", "bill", "null"):
        a = agg.get(g)
        if not a or a["n"] == 0:
            continue
        print(f"{g:10} {a['n']:>3} {a['sum']/a['n']:>9.3f} "
              f"{a['pass']:>3}/{a['n']:<3} {a['pass']/a['n']:>6.0%}")

    # fixed novel-card EBL bill probe
    label, conf = predict.classify(PROBE, tok, model)
    spans = predict.extract(PROBE, tok, model)
    print("\n-- EBL novel-card bill probe --")
    print(f"   class={label} @ {conf:.2f}")
    for s in spans:
        print(f"   {s['ent']:<8} {s['text']!r:12} conf {s['conf']:.2f}")
    print(f"   weakest NERc = {min(s['conf'] for s in spans):.2f} "
          f"-> {'LOCAL' if min(s['conf'] for s in spans) >= GATE and conf >= GATE else 'LLM fallback'}")


if __name__ == "__main__":
    main()
