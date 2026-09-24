"""Build stratified train/val/test splits.

Policy (see config.EVAL_REAL_PER_CLASS):
  - eval (val+test) is 100% REAL: reserve up to EVAL_REAL_PER_CLASS real rows per
    class, split 50/50 into val/test.
  - train = all AUGMENTED rows + all leftover REAL rows (keeps train balanced).
Real is partitioned (no row in two splits); content is already globally deduped,
so there is no train/eval leakage.

A row may carry an explicit `_split` ("train" | "val" | "test") to pin it to that
split, bypassing the reserve logic. Use for regression cases you always want
evaluated (e.g. real SMS a past model got wrong).

Run:  python -m src.split
"""
import json
import random
from collections import defaultdict, Counter

from .config import DATASET, SPLIT_DIR, SEED, EVAL_REAL_PER_CLASS, leaf_label


def main():
    SPLIT_DIR.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]
    rng = random.Random(SEED)

    # explicit per-row overrides win over the reserve logic below
    pinned = {"train": [], "val": [], "test": []}
    auto = []
    for r in rows:
        dst = r.get("_split")
        (pinned[dst] if dst in pinned else auto).append(r)

    aug = [r for r in auto if r.get("_source") == "augmented"]
    real = [r for r in auto if r.get("_source") != "augmented"]

    train = list(aug) + pinned["train"]
    val, test = list(pinned["val"]), list(pinned["test"])

    by = defaultdict(list)
    for r in real:
        by[leaf_label(r)].append(r)

    for lab, items in by.items():
        rng.shuffle(items)
        n_eval = min(len(items), EVAL_REAL_PER_CLASS)
        eval_items = items[:n_eval]
        train += items[n_eval:]  # leftover real -> train
        h = n_eval // 2
        val += eval_items[:h]
        test += eval_items[h:]

    rng.shuffle(train)

    for name, part in [("train", train), ("val", val), ("test", test)]:
        with open(SPLIT_DIR / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for r in part:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    def dist(p):
        return dict(Counter(leaf_label(r) for r in p))

    print("train", len(train), dist(train))
    print("val  ", len(val), dist(val))
    print("test ", len(test), dist(test))


if __name__ == "__main__":
    main()
