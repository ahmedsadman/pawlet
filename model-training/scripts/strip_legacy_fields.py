"""One-shot: drop metadata fields no training code reads.

`_source`, `_relabeled`, `_server_type`, `_server_subtype` and `_variant_of`
are residue from the old generate/rebuild pipeline. `_split` pinned a row to a
split, bypassing the hash; splits are uniform now, so it goes too.

Removes keys only — row count, row order and every surviving key/value are
asserted identical before the file is rewritten.

  python scripts/strip_legacy_fields.py
"""
import json

DATASET = "data/sms-dataset-v1.jsonl"
DROP = {"_source", "_relabeled", "_server_type", "_server_subtype",
        "_variant_of", "_split"}


def main():
    before = [json.loads(l) for l in open(DATASET, encoding="utf-8") if l.strip()]
    after = [{k: v for k, v in r.items() if k not in DROP} for r in before]

    assert len(before) == len(after)
    removed = {}
    for b, a in zip(before, after):
        assert b["message_id"] == a["message_id"], "row order changed"
        gone = set(b) - set(a)
        assert gone <= DROP, f"unexpected key removed: {gone}"
        assert not set(a) - set(b), "key added"
        for k, v in a.items():
            assert b[k] == v, f"value changed: {b['message_id']} {k}"
        for k in gone:
            removed[k] = removed.get(k, 0) + 1

    with open(DATASET, "w", encoding="utf-8") as f:
        for r in after:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    print("removed:", removed, "rows:", len(after))


if __name__ == "__main__":
    main()
