"""Fine-tune the NER (token classification) model for span extraction.

Run:  python -m src.train_ner
Outputs best model + tokenizer to models/ner, prints per-entity seqeval report.
"""
import json
import numpy as np
from datasets import Dataset
from transformers import (
    AutoTokenizer,
    AutoModelForTokenClassification,
    TrainingArguments,
    Trainer,
    DataCollatorForTokenClassification,
    EarlyStoppingCallback,
)
from seqeval.metrics import f1_score as seq_f1, classification_report as seq_report

from .config import BACKBONE, SPLIT_DIR, MODEL_DIR, SEED, EPOCHS
from .prep import NER_LABELS, nlabel2id, nid2label, record_spans, align


def load(split, tok):
    rows = [json.loads(l) for l in open(SPLIT_DIR / f"{split}.jsonl", encoding="utf-8") if l.strip()]
    return Dataset.from_list([align(r["content"], record_spans(r), tok) for r in rows])


def _decode(preds, labels):
    """Drop -100 positions, map ids -> BIO strings for seqeval."""
    tp, tl = [], []
    for pr, la in zip(preds, labels):
        cp, cl = [], []
        for pi, li in zip(pr, la):
            if li == -100:
                continue
            cp.append(nid2label[int(pi)])
            cl.append(nid2label[int(li)])
        tp.append(cp)
        tl.append(cl)
    return tp, tl


def main():
    tok = AutoTokenizer.from_pretrained(BACKBONE)
    ds = {s: load(s, tok) for s in ("train", "val", "test")}

    model = AutoModelForTokenClassification.from_pretrained(
        BACKBONE, num_labels=len(NER_LABELS), id2label=nid2label, label2id=nlabel2id
    )

    def metrics(p):
        preds = np.argmax(p.predictions, axis=2)
        tp, tl = _decode(preds, p.label_ids)
        return {"f1": seq_f1(tl, tp)}

    args = TrainingArguments(
        output_dir=str(MODEL_DIR / "ner"),
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=2,  # keep only best + last checkpoint (avoids filling disk)
        load_best_model_at_end=True,
        metric_for_best_model="f1",
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
        data_collator=DataCollatorForTokenClassification(tok),
        compute_metrics=metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=5)],
    )
    trainer.train()

    print("\n== TEST ==")
    pr = trainer.predict(ds["test"])
    preds = np.argmax(pr.predictions, axis=2)
    tp, tl = _decode(preds, pr.label_ids)
    print(seq_report(tl, tp, digits=3))

    trainer.save_model(str(MODEL_DIR / "ner"))
    tok.save_pretrained(str(MODEL_DIR / "ner"))
    print("saved ->", MODEL_DIR / "ner")


if __name__ == "__main__":
    main()
