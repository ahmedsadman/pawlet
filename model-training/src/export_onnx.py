"""Export trained models to ONNX and dynamic-int8 quantize for on-device use.

Run:  python -m src.export_onnx
Produces models/<kind>_int8/ (model.onnx + tokenizer) ready to ship in the app.

Quantization is dynamic int8 targeting arm64 (Android). Dynamic int8 needs no
calibration data and yields a portable quantized graph.
"""
from transformers import AutoTokenizer
from optimum.onnxruntime import (
    ORTModelForSequenceClassification,
    ORTModelForTokenClassification,
    ORTQuantizer,
)
from optimum.onnxruntime.configuration import AutoQuantizationConfig

from .config import MODEL_DIR


def export(kind: str):
    src = MODEL_DIR / kind
    fp32 = MODEL_DIR / f"{kind}_onnx"
    int8 = MODEL_DIR / f"{kind}_int8"

    Cls = (
        ORTModelForSequenceClassification
        if kind == "classifier"
        else ORTModelForTokenClassification
    )

    # 1) fp32 ONNX export
    m = Cls.from_pretrained(src, export=True)
    m.save_pretrained(fp32)
    AutoTokenizer.from_pretrained(src).save_pretrained(fp32)

    # 2) dynamic int8 quantization (arm64 / mobile)
    q = ORTQuantizer.from_pretrained(fp32)
    qconf = AutoQuantizationConfig.arm64(is_static=False, per_channel=False)
    q.quantize(save_dir=int8, quantization_config=qconf)
    AutoTokenizer.from_pretrained(src).save_pretrained(int8)

    # report size
    onnx_files = list(int8.glob("*.onnx"))
    for f in onnx_files:
        print(f"  {kind} int8: {f.name}  {f.stat().st_size/1e6:.1f} MB")
    print("exported", kind, "->", int8)


if __name__ == "__main__":
    export("classifier")
    export("ner")
