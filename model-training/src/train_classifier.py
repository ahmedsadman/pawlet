"""Fine-tune the sequence classifier (5-way leaf label).

Run:  python -m src.train_classifier
Outputs best model + tokenizer to models/classifier, prints per-class test report.
"""
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
)
from sklearn.metrics import f1_score, accuracy_score, classification_report

from .config import BACKBONE, SPLIT_DIR, MODEL_DIR, CLASS_LABELS, MAX_LEN, SEED, EPOCHS, leaf_label

label2id = {l: i for i, l in enumerate(CLASS_LABELS)}
id2label = {i: l for l, i in label2id.items()}


def load(split):
    rows = [json.loads(l) for l in open(SPLIT_DIR / f"{split}.jsonl", encoding="utf-8") if l.strip()]
    return Dataset.from_list(
        [{"text": r["content"], "label": label2id[leaf_label(r)]} for r in rows]
    )


def main():
    tok = AutoTokenizer.from_pretrained(BACKBONE)
    ds = {s: load(s) for s in ("train", "val", "test")}
    ds = {k: v.map(lambda b: tok(b["text"], truncation=True, max_length=MAX_LEN), batched=True)
          for k, v in ds.items()}

    model = AutoModelForSequenceClassification.from_pretrained(
        BACKBONE, num_labels=len(CLASS_LABELS), id2label=id2label, label2id=label2id
    )

    def metrics(p):
        pred = np.argmax(p.predictions, axis=1)
        return {
            "accuracy": accuracy_score(p.label_ids, pred),
            "macro_f1": f1_score(p.label_ids, pred, average="macro"),
        }

    args = TrainingArguments(
        output_dir=str(MODEL_DIR / "classifier"),
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=2,  # keep only best + last checkpoint (avoids filling disk)
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
        seed=SEED,
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

    print("\n== TEST ==")
    pr = trainer.predict(ds["test"])
    pred = np.argmax(pr.predictions, axis=1)
    print(classification_report(pr.label_ids, pred, target_names=CLASS_LABELS, digits=3))

    trainer.save_model(str(MODEL_DIR / "classifier"))
    tok.save_pretrained(str(MODEL_DIR / "classifier"))
    print("saved ->", MODEL_DIR / "classifier")


if __name__ == "__main__":
    main()
