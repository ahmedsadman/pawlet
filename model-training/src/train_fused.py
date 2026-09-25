"""Fine-tune the FUSED multi-task model (5-way class + token NER, shared backbone).

Seed sweep like train_classifier: trains once per seed, selects the run with the
best VALIDATION combined score = min(class_macro_F1, NER_seqeval_F1). `min` (not
mean) so a collapsed head can't be masked by a strong one — both tasks matter
equally. Saves only the best model to models/fused, then prints its TEST reports.

Run:  python -m src.train_fused
Env:  SEEDS="42,1,7"        # override seed list
      NER_WEIGHT="1.0"      # loss weight on the NER head (class weight fixed 1.0)
                            # small sweep {0.5,1,2} to balance the heads if needed
"""
import os
import json
import numpy as np
import torch
from datasets import Dataset
from transformers import (
    AutoTokenizer,
    TrainingArguments,
    Trainer,
    EarlyStoppingCallback,
    set_seed,
)
from sklearn.metrics import f1_score, classification_report
from seqeval.metrics import f1_score as seq_f1, classification_report as seq_report

from .config import BACKBONE, SPLIT_DIR, MODEL_DIR, CLASS_LABELS, SEED, EPOCHS
from .prep import NER_LABELS, nid2label, cid2label, clabel2id, fused_features
from .model_fused import FusedConfig, FusedModel

SEEDS = [int(s) for s in os.environ.get("SEEDS", f"{SEED},1,7,13,123").split(",")]
NER_WEIGHT = float(os.environ.get("NER_WEIGHT", "1.0"))

OUT = MODEL_DIR / "fused"
TMP = MODEL_DIR / "fused_tmp"  # per-seed checkpoints land here


def load(split, tok):
    rows = [json.loads(l) for l in open(SPLIT_DIR / f"{split}.jsonl", encoding="utf-8") if l.strip()]
    return Dataset.from_list([fused_features(r, tok) for r in rows])


class FusedCollator:
    """Pad input_ids/attention_mask/token_type_ids via the tokenizer; pad
    ner_labels with -100 to the batch max; stack class_labels as a flat 1-D
    tensor. Deliberately NOT a subclass of DataCollatorForTokenClassification —
    that would try to pad the scalar class label into a 2-D tensor."""

    def __init__(self, tok):
        self.tok = tok

    def __call__(self, features):
        class_labels = [f["class_labels"] for f in features]
        ner = [list(f["ner_labels"]) for f in features]
        enc = [
            {k: f[k] for k in f if k not in ("class_labels", "ner_labels")}
            for f in features
        ]
        batch = self.tok.pad(enc, padding=True, return_tensors="pt")
        maxlen = batch["input_ids"].shape[1]
        # tokenizer pads on the right for BERT-family; mirror that for labels.
        batch["ner_labels"] = torch.tensor(
            [row + [-100] * (maxlen - len(row)) for row in ner], dtype=torch.long
        )
        batch["class_labels"] = torch.tensor(class_labels, dtype=torch.long)
        return batch


def _decode_ner(pred_ids, label_ids):
    """Drop -100 positions, map ids -> BIO strings for seqeval."""
    tp, tl = [], []
    for pr, la in zip(pred_ids, label_ids):
        cp, cl = [], []
        for pi, li in zip(pr, la):
            if li == -100:
                continue
            cp.append(nid2label[int(pi)])
            cl.append(nid2label[int(li)])
        tp.append(cp)
        tl.append(cl)
    return tp, tl


def metrics(p):
    # predictions: (class_logits, ner_logits) — model output order.
    # label_ids:   (class_labels, ner_labels) — TrainingArguments.label_names order.
    class_logits, ner_logits = p.predictions
    class_labels, ner_labels = p.label_ids
    cf1 = f1_score(class_labels, np.argmax(class_logits, axis=-1), average="macro")
    tp, tl = _decode_ner(np.argmax(ner_logits, axis=-1), ner_labels)
    nf1 = seq_f1(tl, tp)
    return {"class_f1": cf1, "ner_f1": nf1, "combined": min(cf1, nf1)}


def make_config():
    return FusedConfig(
        backbone=BACKBONE,
        num_class_labels=len(CLASS_LABELS),
        num_ner_labels=len(NER_LABELS),
        class_weight=1.0,
        ner_weight=NER_WEIGHT,
        class_id2label={i: l for i, l in cid2label.items()},
        ner_id2label={i: l for i, l in nid2label.items()},
    )


def train_one(seed, tok, ds):
    """Train one fused model at `seed`; return (trainer, val_combined)."""
    set_seed(seed)  # before building so the NER head init varies with seed
    model = FusedModel.new_pretrained(make_config())
    args = TrainingArguments(
        output_dir=str(TMP),
        eval_strategy="epoch",
        save_strategy="epoch",
        save_total_limit=1,
        load_best_model_at_end=True,
        metric_for_best_model="combined",
        greater_is_better=True,
        label_names=["class_labels", "ner_labels"],  # two label tensors, not "labels"
        remove_unused_columns=False,
        save_safetensors=False,  # avoid shared-tensor serialization edge cases
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
        data_collator=FusedCollator(tok),
        compute_metrics=metrics,
        callbacks=[EarlyStoppingCallback(early_stopping_patience=5)],
    )
    trainer.train()
    ev = trainer.evaluate(ds["val"])
    return trainer, ev


def main():
    tok = AutoTokenizer.from_pretrained(BACKBONE)
    ds = {s: load(s, tok) for s in ("train", "val", "test")}

    best = {"combined": -1.0, "seed": None, "trainer": None}
    for seed in SEEDS:
        trainer, ev = train_one(seed, tok, ds)
        c, n, comb = ev["eval_class_f1"], ev["eval_ner_f1"], ev["eval_combined"]
        print(f"[seed {seed}] val class_f1={c:.4f}  ner_f1={n:.4f}  combined={comb:.4f}")
        if comb > best["combined"]:
            best.update(combined=comb, seed=seed, trainer=trainer)

    print(f"\n== BEST: seed {best['seed']}  val combined {best['combined']:.4f} "
          f"(ner_weight={NER_WEIGHT}) ==")
    trainer = best["trainer"]

    print("\n== TEST (best-by-val model) ==")
    pr = trainer.predict(ds["test"])
    class_logits, ner_logits = pr.predictions
    class_labels, ner_labels = pr.label_ids

    print("\n----- CLASSIFICATION (per-class) -----")
    print(classification_report(
        class_labels, np.argmax(class_logits, axis=-1),
        target_names=CLASS_LABELS, digits=3,
    ))
    print("----- NER (seqeval, per-entity) -----")
    tp, tl = _decode_ner(np.argmax(ner_logits, axis=-1), ner_labels)
    print(seq_report(tl, tp, digits=3))

    trainer.save_model(str(OUT))
    tok.save_pretrained(str(OUT))
    print("saved ->", OUT)


if __name__ == "__main__":
    main()
