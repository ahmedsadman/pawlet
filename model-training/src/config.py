"""Central config + label definitions shared by all training scripts."""
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = ROOT / "data"
DATASET = DATA_DIR / "sms-dataset-v1.jsonl"
SPLIT_DIR = DATA_DIR / "splits"
MODEL_DIR = ROOT / "models"

# Pretrained encoder backbone (AutoModel* resolves the head).
# Swap freely — code is backbone-agnostic. Size/quality trade-offs (int8 export):
#   huawei-noah/TinyBERT_General_4L_312D   ~15 MB   smallest
#   google/mobilebert-uncased              ~25 MB   good default
#   microsoft/MiniLM-L12-H384-uncased      ~22 MB
#   distilbert-base-uncased                ~65 MB   most documented, biggest
BACKBONE = "google/mobilebert-uncased"

SEED = 42
MAX_LEN = 128  # bank SMS are short; 128 tokens is plenty
EPOCHS = int(os.environ.get("EPOCHS", 30))  # override for smoke tests: EPOCHS=1

# --- classification: single 5-way leaf label (category + transaction type) ---
CLASS_LABELS = ["expense", "income", "transfer", "bill", "null"]

# --- NER (token classification), BIO. currency is NOT here: currency_span has
# no char offsets, so currency is derived in the app from the token next to the
# amount. Add it later if you also store currency offsets. ---
NER_ENTITIES = ["AMOUNT", "BALANCE", "DUE", "PERIOD"]

# Split policy. Evaluation stays 100% REAL. For each class we reserve up to
# EVAL_REAL_PER_CLASS real rows for eval (split 50/50 val/test); ALL remaining
# real rows plus ALL augmented rows go to train. This keeps eval honest while
# balancing the train set (otherwise expense, which is mostly real, would be
# starved in train). Minority classes with few real rows contribute them all to
# eval and train on synthetic only — unavoidable until more real data arrives.
EVAL_REAL_PER_CLASS = 30


def leaf_label(rec: dict) -> str:
    """Map a dataset record to its single classification label."""
    cat = rec.get("category")
    if cat == "bill":
        return "bill"
    if cat is None:
        return "null"
    return rec["type"]  # income | expense | transfer
