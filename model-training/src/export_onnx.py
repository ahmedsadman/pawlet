"""Export the trained FUSED model to ONNX and dynamic-int8 quantize for on-device.

Run:  python -m src.export_onnx
Produces:
  models/fused_onnx/model.onnx   fp32 (two outputs: class_logits, ner_logits)
  models/fused_int8/model.onnx   dynamic int8 (ship this + tokenizer in the app)

optimum's ORTModelFor* classes can't auto-export a custom two-head model, so we
export the graph by hand with torch.onnx.export (two named outputs, dynamic batch
+ sequence axes) and quantize the raw .onnx with onnxruntime's quantize_dynamic
(ORTQuantizer assumes an optimum model directory). A post-quantization parity
check confirms the ONNX outputs still match PyTorch on real SMS.
"""
import numpy as np
import torch
import onnxruntime as ort
from onnxruntime.quantization import quantize_dynamic, QuantType
from transformers import AutoTokenizer

from .config import MODEL_DIR, MAX_LEN
from .model_fused import FusedModel

FUSED_DIR = MODEL_DIR / "fused"
INPUTS = ("input_ids", "attention_mask", "token_type_ids")

# real-ish bank SMS covering both tasks — used only for the parity check.
PARITY_SAMPLES = [
    "Your A/C debited by Tk 500.00. Balance Tk 1,200.50 on 12-05-24.",
    "You have received BDT 3,000 from John. Available balance BDT 8,500.",
    "Your bill of Tk 1,499 is due on 25 May 2024. Please pay to avoid charges.",
    "Transferred Tk 2,000 to 017XXXXXXXX. Ref 998877.",
    "OTP 123456. Do not share with anyone.",
]


class _ExportWrapper(torch.nn.Module):
    """Positional-args, tuple-output wrapper so torch.onnx.export gets a clean
    signature (input_ids, attention_mask, token_type_ids) -> (class, ner)."""

    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, input_ids, attention_mask, token_type_ids):
        o = self.model(
            input_ids=input_ids,
            attention_mask=attention_mask,
            token_type_ids=token_type_ids,
        )
        return o.class_logits, o.ner_logits


def _feed(tok, text):
    enc = tok(text, truncation=True, max_length=MAX_LEN, return_tensors="pt")
    if "token_type_ids" not in enc:
        enc["token_type_ids"] = torch.zeros_like(enc["input_ids"])
    return enc


def _softmax(x, axis=-1):
    e = np.exp(x - x.max(axis=axis, keepdims=True))
    return e / e.sum(axis=axis, keepdims=True)


def export():
    fp32_dir = MODEL_DIR / "fused_onnx"
    int8_dir = MODEL_DIR / "fused_int8"
    fp32_dir.mkdir(parents=True, exist_ok=True)
    int8_dir.mkdir(parents=True, exist_ok=True)
    fp32 = fp32_dir / "model.onnx"
    int8 = int8_dir / "model.onnx"

    tok = AutoTokenizer.from_pretrained(FUSED_DIR)
    model = FusedModel.from_pretrained(FUSED_DIR).eval()
    model._ner_id2label = {int(k): v for k, v in model.config.ner_id2label.items()}

    enc = _feed(tok, "dummy text for tracing the graph")
    args = tuple(enc[k] for k in INPUTS)

    # 1) fp32 ONNX export, two outputs, dynamic batch + sequence.
    torch.onnx.export(
        _ExportWrapper(model),
        args,
        str(fp32),
        input_names=list(INPUTS),
        output_names=["class_logits", "ner_logits"],
        dynamic_axes={
            "input_ids": {0: "batch", 1: "sequence"},
            "attention_mask": {0: "batch", 1: "sequence"},
            "token_type_ids": {0: "batch", 1: "sequence"},
            "class_logits": {0: "batch"},
            "ner_logits": {0: "batch", 1: "sequence"},
        },
        opset_version=17,
        do_constant_folding=True,
        dynamo=False,
    )
    tok.save_pretrained(fp32_dir)

    # 2) dynamic int8 quantization on the raw graph (arm64 / mobile).
    quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QInt8)
    tok.save_pretrained(int8_dir)

    for f, tag in ((fp32, "fp32"), (int8, "int8")):
        print(f"  fused {tag}: {f.name}  {f.stat().st_size / 1e6:.1f} MB")

    # 3) post-quantization parity check (int8 ONNX vs PyTorch) on real SMS.
    _parity(tok, model, int8)
    print("exported fused ->", int8_dir)


def _parity(tok, model, int8_path):
    """Confirm the int8 ONNX graph makes the SAME decisions as PyTorch.

    Int8 quantization deliberately changes float outputs, so we assert on the
    argmax LABELS (class + per-token NER), not on probability magnitudes. The
    max class-prob delta is reported for information only — expected to be
    nonzero after quantization.
    """
    sess = ort.InferenceSession(str(int8_path), providers=["CPUExecutionProvider"])
    max_cls_delta = 0.0
    cls_agree, ner_agree, ner_total = 0, 0, 0

    for text in PARITY_SAMPLES:
        enc = _feed(tok, text)
        with torch.no_grad():
            o = model(**enc)
        pt_cls = torch.softmax(o.class_logits[0], -1).numpy()
        pt_cls_id = int(pt_cls.argmax())
        pt_ner = o.ner_logits[0].argmax(-1).numpy()

        feeds = {k: enc[k].numpy() for k in INPUTS}
        ox_cls_logits, ox_ner_logits = sess.run(["class_logits", "ner_logits"], feeds)
        ox_cls = _softmax(ox_cls_logits[0])
        ox_ner = ox_ner_logits[0].argmax(-1)

        max_cls_delta = max(max_cls_delta, float(np.abs(pt_cls - ox_cls).max()))
        cls_agree += pt_cls_id == int(ox_cls.argmax())
        ner_agree += int((pt_ner == ox_ner).sum())
        ner_total += len(pt_ner)

    n = len(PARITY_SAMPLES)
    ner_rate = ner_agree / max(ner_total, 1)
    print(f"  parity: class label agreement {cls_agree}/{n}  "
          f"NER token agreement {ner_agree}/{ner_total} ({ner_rate:.1%})  "
          f"(class prob drift {max_cls_delta:.3f}, int8 noise — informational)")
    # decisions must survive quantization; float drift is expected and ignored.
    assert cls_agree == n, f"class labels changed under int8: {cls_agree}/{n}"
    assert ner_rate >= 0.98, f"NER labels drifted under int8: {ner_rate:.1%}"
    print("  parity OK")


if __name__ == "__main__":
    export()
