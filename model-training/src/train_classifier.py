"""Fine-tune the sequence classifier (5-way leaf label).

Seed sweep: trains once per seed, selects the run with the best VALIDATION
macro-F1, saves only that model to models/classifier, then prints its TEST
report. Selecting on val (never test) keeps the test set an honest estimate.

Run:  python -m src.train_classifier
Env:  SEEDS="42,1,7"   # override the seed list (default below)
"""
import os
import json
import numpy as np
from datasets import Dataset
from transformers import (
    AutoTokenizer,
    AutoModelForSequenceClassification,
    TrainingArguments,
    Trainer,
    DataCollatorWithPadding,
    EarlyStoppingCallback,
    set_seed,
)
from sklearn.metrics import f1_score, accuracy_score, classification_report

from .config import BACKBONE, SPLIT_DIR, MODEL_DIR, CLASS_LABELS, MAX_LEN, SEED, EPOCHS, leaf_label

label2id = {l: i for i, l in enumerate(CLASS_LABELS)}
id2label = {i: l for l, i in label2id.items()}

SEEDS = [int(s) for s in os.environ.get("SEEDS", f"{SEED},1,7,13,123").split(",")]

OUT = MODEL_DIR / "classifier"
TMP = MODEL_DIR / "classifier_tmp"  # per-seed checkpoints land here


def load(split, tok):
    rows = [json.loads(l) for l in open(SPLIT_DIR / f"{split}.jsonl", encoding="utf-8") if l.strip()]
    ds = Dataset.from_list(
        [{"text": r["content"], "label": label2id[leaf_label(r)]} for r in rows]
    )
    return ds.map(lambda b: tok(b["text"], truncation=True, max_length=MAX_LEN), batched=True)


def metrics(p):
    pred = np.argmax(p.predictions, axis=1)
    return {
        "accuracy": accuracy_score(p.label_ids, pred),
        "macro_f1": f1_score(p.label_ids, pred, average="macro"),
    }


def train_one(seed, tok, ds):
    """Train one classifier at `seed`; return (trainer, val_macro_f1)."""
    set_seed(seed)  # before from_pretrained so the classification head init varies
    model = AutoModelForSequenceClassification.from_pretrained(
        BACKBONE, num_labels=len(CLASS_LABELS), id2label=id2label, label2id=label2id
    )
    args = TrainingArguments(
        output_dir=str(TMP),
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=1,
        load_best_model_at_end=True,
        metric_for_best_model="macro_f1",
        greater_is_better=True,
        learning_rate=5e-5,
        warmup_ratio=0.1,
        per_device_train_batch_size=16,
        per_device_eval_batch_size=32,
        num_train_epochs=EPOCHS,
        weight_decay=0.01,
        logging_steps=20,
        seed=seed,
        report_to="none",
    )
    trainer = Trainer(
        model=model,
        args=args,
        train_dataset=ds["train"],
        eval_dataset=ds["val"],
        processing_class=tok,
        data_collator=DataCollatorWithPadding(tok),
        compute_metrics=metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=5)],
    )
    trainer.train()
    val_f1 = trainer.evaluate(ds["val"])["eval_macro_f1"]
    return trainer, val_f1


def main():
    tok = AutoTokenizer.from_pretrained(BACKBONE)
    ds = {s: load(s, tok) for s in ("train", "val", "test")}

    best = {"val_f1": -1.0, "seed": None, "trainer": None}
    for seed in SEEDS:
        trainer, val_f1 = train_one(seed, tok, ds)
        print(f"[seed {seed}] val macro_f1 = {val_f1:.4f}")
        if val_f1 > best["val_f1"]:
            best.update(val_f1=val_f1, seed=seed, trainer=trainer)

    print(f"\n== BEST: seed {best['seed']}  val macro_f1 {best['val_f1']:.4f} ==")
    trainer = best["trainer"]

    print("\n== TEST (best-by-val model) ==")
    pr = trainer.predict(ds["test"])
    pred = np.argmax(pr.predictions, axis=1)
    print(classification_report(pr.label_ids, pred, target_names=CLASS_LABELS, digits=3))

    trainer.save_model(str(OUT))
    tok.save_pretrained(str(OUT))
    print("saved ->", OUT)


if __name__ == "__main__":
    main()
