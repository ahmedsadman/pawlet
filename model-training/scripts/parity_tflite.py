"""Parity check: the SHIPPED TFLite model must reproduce PyTorch's decisions.

Compares the quantized tflite actually bundled in the app
(mobile-app/assets/model/model.tflite) against the fp32 PyTorch FusedModel on a
handful of real-ish bank SMS. Dynamic-range int8 deliberately changes float
outputs, so we assert on the argmax LABELS (class + per-token NER), not on
probability magnitudes.

Torch and TensorFlow segfault when imported into the same process (ABI clash), so
this runs PyTorch inference in a child process (`--emit-torch`, torch-only) that
prints the expected labels as JSON, then compares against the tflite in the parent
(tensorflow-only). Outputs are resolved BY SHAPE (tf.lite drops the ONNX output
names): class = rank-2 [.,|labels|], ner = rank-3 [.,.,NUM_NER].

Run from model-training/ (after export_tflite.py):
    python scripts/parity_tflite.py
"""
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from src.config import CLASS_LABELS, MAX_LEN, MODEL_DIR, NER_ENTITIES  # noqa: E402

FUSED_DIR = MODEL_DIR / "fused"
TFLITE = ROOT.parent / "mobile-app" / "assets" / "model" / "model.tflite"
INPUTS = ("input_ids", "attention_mask", "token_type_ids")
NUM_NER_LABELS = 2 * len(NER_ENTITIES) + 1

PARITY_SAMPLES = [
    "Your A/C debited by Tk 500.00. Balance Tk 1,200.50 on 12-05-24.",
    "You have received BDT 3,000 from John. Available balance BDT 8,500.",
    "Your bill of Tk 1,499 is due on 25 May 2024. Please pay to avoid charges.",
    "Transferred Tk 2,000 to 017XXXXXXXX. Ref 998877.",
    "OTP 123456. Do not share with anyone.",
]


def emit_torch():
    """Child process (torch-only): print [{ids, cls, ner}] as JSON."""
    import torch
    from transformers import AutoTokenizer
    from src.model_fused import FusedModel

    tok = AutoTokenizer.from_pretrained(FUSED_DIR)
    model = FusedModel.from_pretrained(FUSED_DIR).eval()
    out = []
    for text in PARITY_SAMPLES:
        enc = tok(text, truncation=True, max_length=MAX_LEN, return_tensors="pt")
        if "token_type_ids" not in enc:
            enc["token_type_ids"] = torch.zeros_like(enc["input_ids"])
        with torch.no_grad():
            o = model(**enc)
        out.append({
            "ids": enc["input_ids"][0].tolist(),
            "cls": int(o.class_logits[0].argmax()),
            "ner": o.ner_logits[0].argmax(-1).tolist(),
        })
    print(json.dumps(out))


def main():
    if not TFLITE.exists():
        sys.exit(f"missing {TFLITE} — run `python scripts/export_tflite.py` first")

    # 1) expected labels from PyTorch, in a torch-only child process.
    proc = subprocess.run(
        [sys.executable, __file__, "--emit-torch"],
        check=True, capture_output=True, text=True,
    )
    expected = json.loads(proc.stdout)

    # 2) tflite inference (tensorflow-only in this process).
    import numpy as np
    import tensorflow as tf

    interp = tf.lite.Interpreter(model_path=str(TFLITE))
    interp.allocate_tensors()
    ins = {d["name"]: d["index"] for d in interp.get_input_details()}
    in_idx = {k: next(i for n, i in ins.items() if k in n) for k in INPUTS}
    outs = interp.get_output_details()
    cls_o = next(o["index"] for o in outs
                 if len(o["shape"]) == 2 and int(o["shape"][-1]) == len(CLASS_LABELS))
    ner_o = next(o["index"] for o in outs
                 if len(o["shape"]) == 3 and int(o["shape"][-1]) == NUM_NER_LABELS)

    cls_agree, ner_agree, ner_total = 0, 0, 0
    for r in expected:
        ids = r["ids"]
        n = len(ids)
        pad = lambda seq: np.pad(np.array(seq, np.int32), (0, MAX_LEN - len(seq)))[None]
        interp.set_tensor(in_idx["input_ids"], pad(ids))
        interp.set_tensor(in_idx["attention_mask"], pad([1] * n))
        interp.set_tensor(in_idx["token_type_ids"], pad([0] * n))
        interp.invoke()
        tf_cls = int(interp.get_tensor(cls_o)[0].argmax())
        tf_ner = interp.get_tensor(ner_o)[0].argmax(-1)[:n]
        cls_agree += r["cls"] == tf_cls
        ner_agree += int((np.array(r["ner"]) == tf_ner).sum())
        ner_total += n

    n = len(expected)
    ner_rate = ner_agree / max(ner_total, 1)
    print(f"  parity: class label agreement {cls_agree}/{n}  "
          f"NER token agreement {ner_agree}/{ner_total} ({ner_rate:.1%})")
    assert cls_agree == n, f"class labels changed under quant: {cls_agree}/{n}"
    assert ner_rate >= 0.98, f"NER labels drifted under quant: {ner_rate:.1%}"
    print("  parity OK")


if __name__ == "__main__":
    if "--emit-torch" in sys.argv:
        emit_torch()
    else:
        main()
