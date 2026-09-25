"""Export the fused model to a TFLite flatbuffer for on-device (LiteRT) use.

Pipeline: the fp32 ONNX graph (models/fused_onnx/model.onnx, produced by
`python -m src.export_onnx`) -> retype the three inputs from int64 to int32 (with
Cast-to-int64 nodes so the rest of the graph is unchanged) -> onnx2tf ->
model_float32.tflite, copied to the app's assets.

Why int32 inputs: the Flutter `tflite_flutter` package writes int64 input tensors
in big-endian (a bug), corrupting token ids on little-endian devices. int32
inputs use its correct little-endian path. BERT token ids/masks fit in int32.

The app ships the FLOAT32 tflite. A smaller float16 build (half the size) is
produced by onnx2tf too, but its float16 *output* tensors don't load through
tflite_flutter here; shrinking the shipped model (float16 with float32 IO, or
int8) is a tracked follow-up.

Prereqs (in the training venv):
    pip install onnx2tf tensorflow onnx_graphsurgeon onnxruntime sng4onnx onnxsim

Run from model-training/:
    python -m src.export_onnx      # first, to refresh models/fused_onnx/model.onnx
    python scripts/export_tflite.py
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import onnx
from onnx import TensorProto, helper

ROOT = Path(__file__).resolve().parent.parent
FP32_ONNX = ROOT / "models" / "fused_onnx" / "model.onnx"
APP_ASSET = ROOT.parent / "mobile-app" / "assets" / "model" / "model.tflite"
INPUTS = ("input_ids", "attention_mask", "token_type_ids")


def retype_inputs_to_int32(src: Path, dst: Path) -> None:
    """Rewrite int64 graph inputs to int32, inserting Cast->int64 for consumers."""
    model = onnx.load(str(src))
    graph = model.graph
    casts, rename = [], {}
    for inp in graph.input:
        if inp.type.tensor_type.elem_type != TensorProto.INT64:
            continue
        orig = inp.name
        inp.type.tensor_type.elem_type = TensorProto.INT32
        casted = orig + "_i64"
        rename[orig] = casted
        casts.append(
            helper.make_node("Cast", [orig], [casted], to=TensorProto.INT64,
                             name="cast_" + orig)
        )
    for node in graph.node:
        for i, vin in enumerate(node.input):
            if vin in rename:
                node.input[i] = rename[vin]
    new_nodes = casts + list(graph.node)
    del graph.node[:]
    graph.node.extend(new_nodes)
    onnx.checker.check_model(model)
    onnx.save(model, str(dst))


def main() -> None:
    if not FP32_ONNX.exists():
        sys.exit(f"missing {FP32_ONNX} — run `python -m src.export_onnx` first")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        int32_onnx = tmp / "model_int32in.onnx"
        retype_inputs_to_int32(FP32_ONNX, int32_onnx)

        out_dir = tmp / "tflite"
        subprocess.run(
            ["onnx2tf", "-i", str(int32_onnx), "-o", str(out_dir),
             "-kat", *INPUTS],
            check=True,
        )
        produced = out_dir / "model_int32in_float32.tflite"
        if not produced.exists():
            sys.exit(f"onnx2tf did not produce {produced}")
        APP_ASSET.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(produced, APP_ASSET)
        size_mb = APP_ASSET.stat().st_size / 1e6
        print(f"wrote {APP_ASSET}  ({size_mb:.0f} MB)")


if __name__ == "__main__":
    main()
