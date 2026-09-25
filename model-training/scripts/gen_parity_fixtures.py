"""Emit golden tokenizer + model fixtures for the Flutter parity tests.

Runs the SAME HF tokenizer the training used and the fused model, dumping a JSON
the Dart side asserts against. Tokenizer parity (input_ids + offsets) is checked
on the host VM; the model-output section is used by the on-device integration
check. Run from model-training/ with the venv active:

    python -m scripts.gen_parity_fixtures
"""
import json
from pathlib import Path

from transformers import AutoTokenizer

from src.config import MAX_LEN
from src.predict import load, classify, extract

FUSED_INT8 = Path("models/fused_int8")
OUT = Path("../mobile-app/test/fixtures/local_model_parity.json")

SAMPLES = [
    'Your A/C debited by Tk 500.00. Balance Tk 1,200.50 on 12-05-24.',
    'You have received BDT 3,000 from John. Available balance BDT 8,500.',
    'Monthly bill 423800******3241 AUG2026; Total Due: BDT 4924.35, Min Due: BDT 4833.35',
    'Your bill for card 498851******3711 for JUL 2026 BDT 4111.79 Min due: BDT 500',
    'OTP 123456. Do not share with anyone.',
]


# Label orders the app hardcodes (mobile-app/.../local_model.dart). Asserted
# against the trained model below so a class/entity reorder can't silently ship.
APP_CLASS_LABELS = ["expense", "income", "transfer", "bill", "null"]
APP_NER_LABELS = [
    "O", "B-AMOUNT", "I-AMOUNT", "B-BALANCE", "I-BALANCE",
    "B-DUE", "I-DUE", "B-PERIOD", "I-PERIOD",
]


def _assert_label_order(model):
    got_class = [model._class_id2label[i] for i in range(len(APP_CLASS_LABELS))]
    got_ner = [model._ner_id2label[i] for i in range(len(APP_NER_LABELS))]
    assert got_class == APP_CLASS_LABELS, (
        f"class label order drift vs the app's kClassLabels: {got_class}")
    assert got_ner == APP_NER_LABELS, (
        f"ner label order drift vs the app's kNerLabels: {got_ner}")


def main():
    tok = AutoTokenizer.from_pretrained(FUSED_INT8)
    models = load()  # (tokenizer, model) for the predict helpers
    _assert_label_order(models[1])
    records = []
    for text in SAMPLES:
        enc = tok(text, truncation=True, max_length=MAX_LEN,
                  return_offsets_mapping=True)
        label, conf = classify(text, *models)
        spans = extract(text, *models)
        records.append({
            "text": text,
            "input_ids": enc["input_ids"],
            "offsets": [list(o) for o in enc["offset_mapping"]],
            "class_label": label,
            "class_conf": round(conf, 4),
            "spans": [
                {"ent": s["ent"], "text": s["text"], "conf": round(s["conf"], 4)}
                for s in spans
            ],
        })
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(records, ensure_ascii=False, indent=2))
    print(f"wrote {len(records)} fixtures -> {OUT}")


if __name__ == "__main__":
    main()
