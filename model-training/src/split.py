"""Build stratified train/val/test splits.

Policy: 70/15/15 per leaf class, ordered by a hash of the row's content. Hashing
(rather than shuffling) keeps the order stable as the dataset grows, so adding
rows only moves the few that sit next to a cut boundary instead of reshuffling
everything — metrics stay comparable across runs.

A row may carry an explicit `_split` ("train" | "val" | "test") to pin it to that
split. Use for regression cases you always want evaluated (e.g. a real SMS a past
model got wrong).

Run:  python -m src.split
"""
import hashlib
import json
from collections import defaultdict, Counter

from .config import DATASET, SPLIT_DIR, SEED, VAL_FRAC, TEST_FRAC, leaf_label

BUCKETS = 10_000


def bucket(content: str) -> int:
    """Stable 0..BUCKETS-1 position for a row, from its content."""
    digest = hashlib.sha1(f"{SEED}:{content}".encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % BUCKETS


def main():
    SPLIT_DIR.mkdir(parents=True, exist_ok=True)
    rows = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]

    parts = {"train": [], "val": [], "test": []}
    auto = defaultdict(list)
    for r in rows:
        dst = r.get("_split")
        if dst in parts:
            parts[dst].append(r)
        else:
            auto[leaf_label(r)].append(r)

    # Stratify: order each class by hash bucket, then cut at the fractions. The
    # cut is positional so small classes still get val/test rows, which a raw
    # bucket threshold would not guarantee.
    val_end = VAL_FRAC + TEST_FRAC
    for items in auto.values():
        items.sort(key=lambda r: (bucket(r["content"]), r["message_id"]))
        n = len(items)
        for i, r in enumerate(items):
            pos = i / n
            if pos < VAL_FRAC:
                parts["val"].append(r)
            elif pos < val_end:
                parts["test"].append(r)
            else:
                parts["train"].append(r)

    for name, part in parts.items():
        part.sort(key=lambda r: r["message_id"])
        with open(SPLIT_DIR / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for r in part:
                f.write(json.dumps(r, ensure_ascii=False) + "\n")

    def dist(p):
        return dict(Counter(leaf_label(r) for r in p))

    for name in ("train", "val", "test"):
        print(f"{name:6}", len(parts[name]), dist(parts[name]))


if __name__ == "__main__":
    main()
