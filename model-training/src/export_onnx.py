"""Export the trained FUSED model to fp32 ONNX — the source graph for TFLite.

Run:  python -m src.export_onnx
Produces:
  models/fused_onnx/model.onnx   fp32 (two outputs: class_logits, ner_logits)

This graph is NOT shipped directly. It is the input to `scripts/export_tflite.py`,
which runs it through onnx2tf (with dynamic-range int8 quantization) to produce the
TFLite flatbuffer bundled in the app. On-device shrinking/quantization happens in
that TFLite step, not here.

optimum's ORTModelFor* classes can't auto-export a custom two-head model, so we
export the graph by hand with torch.onnx.export (two named outputs, dynamic batch
+ sequence axes).
"""
import torch
from transformers import AutoTokenizer

from .config import MODEL_DIR, MAX_LEN
from .model_fused import FusedModel

FUSED_DIR = MODEL_DIR / "fused"
INPUTS = ("input_ids", "attention_mask", "token_type_ids")


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


def export():
    fp32_dir = MODEL_DIR / "fused_onnx"
    fp32_dir.mkdir(parents=True, exist_ok=True)
    fp32 = fp32_dir / "model.onnx"

    tok = AutoTokenizer.from_pretrained(FUSED_DIR)
    model = FusedModel.from_pretrained(FUSED_DIR).eval()
    model._ner_id2label = {int(k): v for k, v in model.config.ner_id2label.items()}

    enc = _feed(tok, "dummy text for tracing the graph")
    args = tuple(enc[k] for k in INPUTS)

    # fp32 ONNX export, two outputs, dynamic batch + sequence.
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

    print(f"  fused fp32: {fp32.name}  {fp32.stat().st_size / 1e6:.1f} MB")
    print("exported fused ->", fp32_dir)
    print("next: python scripts/export_tflite.py  (quantizes to TFLite for the app)")


if __name__ == "__main__":
    export()
