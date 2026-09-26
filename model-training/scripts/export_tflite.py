"""Export the fused model to a dynamic-range int8 TFLite flatbuffer for on-device.

Pipeline: the fp32 ONNX graph (models/fused_onnx/model.onnx, produced by
`python -m src.export_onnx`) -> retype the three inputs from int64 to int32 (with
Cast-to-int64 nodes so the rest of the graph is unchanged) -> onnx2tf, with input
shapes pinned static [1, MAX_LEN], emitting a TF SavedModel -> tf.lite converter
with dynamic-range int8 quantization -> mobile-app/assets/model/model.tflite.

Why this exact route (learned the hard way against onnx2tf 2.6.9):
  * onnx2tf's own quantizers don't fit: -oiqt forces STRICT full-integer int8
    (int8 IO + a required calibration dataset); the flatbuffer_direct backend's
    -odrqt is a stub (no real weight shrink, stayed ~99 MB); its float16 build
    ships float16 IO which tflite_flutter can't load.
  * So we let onnx2tf produce only a TF SavedModel (-fdosm) and quantize it
    ourselves with tf.lite.Optimize.DEFAULT = dynamic-range int8: int8 *weights*,
    float32 *activations + IO*, NO calibration data. Result ~26 MB, float32 IO.
  * Input shapes MUST be pinned static (-ois): with dynamic batch/sequence axes
    the SavedModel export crashes (Gather/Slice on symbolic dims). The app always
    runs a fixed [1, MAX_LEN] window anyway.

Why int32 inputs: the Flutter `tflite_flutter` package writes int64 input tensors
in big-endian (a bug), corrupting token ids on little-endian devices. int32
inputs use its correct little-endian path. BERT token ids/masks fit in int32.

Output names/order: tf.lite's SavedModel converter renames the two outputs to
`PartitionedCall:0/1` and does NOT preserve order, so the app and the gate below
resolve the class vs NER head BY SHAPE (class = rank-2 [.,|labels|], ner = rank-3
[.,.,NUM_NER]) rather than by name. Input names keep the ONNX substrings
(`serving_default_input_ids:0` etc.), so inputs stay name-resolved.

Prereqs (in the training venv):
    pip install -r requirements.txt   # onnx2tf[tensorflow]==2.6.9 + onnx_graphsurgeon

Run from model-training/:
    python -m src.export_onnx      # first, to refresh models/fused_onnx/model.onnx
    python scripts/export_tflite.py
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import onnx
from onnx import TensorProto, helper

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from src.config import CLASS_LABELS, MAX_LEN, NER_ENTITIES  # noqa: E402

FP32_ONNX = ROOT / "models" / "fused_onnx" / "model.onnx"
APP_ASSET = ROOT.parent / "mobile-app" / "assets" / "model" / "model.tflite"
INPUTS = ("input_ids", "attention_mask", "token_type_ids")
# BIO tagging: B-/I- per entity + one O label.
NUM_NER_LABELS = 2 * len(NER_ENTITIES) + 1


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


def _find_saved_model(root: Path) -> Path:
    """Locate the dir containing saved_model.pb under onnx2tf's output."""
    if (root / "saved_model.pb").exists():
        return root
    hits = list(root.rglob("saved_model.pb"))
    if not hits:
        sys.exit(f"onnx2tf produced no SavedModel under {root} (-fdosm failed?)")
    return hits[0].parent


def verify_shipped_model(path: Path) -> None:
    """Hard gate: fail the build unless the tflite matches the app's contract.

    Outputs are resolved BY SHAPE (tf.lite loses the ONNX names -> PartitionedCall
    and does not preserve order): exactly one rank-2 [.,|labels|] (class) and one
    rank-3 [.,.,NUM_NER] (ner). Inputs keep the ONNX name substrings. Also asserts
    int32-in / float32-out (an accidental full-integer int8 export would give int8
    IO and silently produce garbage on device).
    """
    import numpy as np
    import tensorflow as tf  # local import: only needed at export time

    interp = tf.lite.Interpreter(model_path=str(path))
    interp.allocate_tensors()
    ins = interp.get_input_details()
    outs = interp.get_output_details()

    def fail(msg):
        sys.exit(f"EXPORT GATE FAILED for {path.name}: {msg}")

    # inputs: all three named (order-robust; the app looks them up by name).
    in_names = " ".join(t["name"] for t in ins)
    for want in INPUTS:
        if want not in in_names:
            fail(f"missing input '{want}' — have: {in_names}")
    for t in ins:
        if t["dtype"] != np.int32:
            fail(f"input '{t['name']}' dtype {t['dtype']}, expected int32")

    # outputs: shape-disambiguated class vs ner (names/order are not reliable).
    if len(outs) != 2:
        fail(f"expected 2 outputs, got {len(outs)}")
    for t in outs:
        if t["dtype"] != np.float32:
            fail(f"output '{t['name']}' dtype {t['dtype']}, expected float32")
    cls = [t for t in outs if len(t["shape"]) == 2 and int(t["shape"][-1]) == len(CLASS_LABELS)]
    ner = [t for t in outs if len(t["shape"]) == 3 and int(t["shape"][-1]) == NUM_NER_LABELS]
    if len(cls) != 1 or len(ner) != 1:
        shapes = [list(t["shape"]) for t in outs]
        fail(f"cannot shape-disambiguate outputs {shapes}: need one [.,{len(CLASS_LABELS)}] "
             f"(class) + one [.,.,{NUM_NER_LABELS}] (ner)")

    print(f"  gate OK: class {list(cls[0]['shape'])} + ner {list(ner[0]['shape'])}, "
          "int32 in / float32 out (outputs shape-resolved)")


def main() -> None:
    if not FP32_ONNX.exists():
        sys.exit(f"missing {FP32_ONNX} — run `python -m src.export_onnx` first")

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        int32_onnx = tmp / "model_int32in.onnx"
        retype_inputs_to_int32(FP32_ONNX, int32_onnx)

        out_dir = tmp / "tf"
        bin_dir = Path(sys.executable).parent
        onnx2tf_cmd = str(bin_dir / "onnx2tf") if (bin_dir / "onnx2tf").exists() else "onnx2tf"
        # onnx2tf shells out to onnxsim/sne4onnx/sng4onnx; put the venv's console
        # scripts on PATH for those child processes.
        env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ.get('PATH', '')}"}
        static = [f"{name}:1,{MAX_LEN}" for name in INPUTS]
        # 1) onnx2tf -> TF SavedModel with static [1, MAX_LEN] input shapes.
        subprocess.run(
            [onnx2tf_cmd, "-i", str(int32_onnx), "-o", str(out_dir),
             "-fdosm",        # emit a SavedModel (for our own quantizer below)
             "-coion",        # copy ONNX IO names through where possible
             "-ois", *static,  # pin static input shapes (dynamic axes crash export)
             "-kat", *INPUTS],
            check=True,
            env=env,
        )
        saved_model_dir = _find_saved_model(out_dir)

        # 2) dynamic-range int8: int8 weights, float32 activations + IO, no calib.
        import tensorflow as tf
        conv = tf.lite.TFLiteConverter.from_saved_model(str(saved_model_dir))
        conv.optimizations = [tf.lite.Optimize.DEFAULT]
        tflite_bytes = conv.convert()

        APP_ASSET.parent.mkdir(parents=True, exist_ok=True)
        APP_ASSET.write_bytes(tflite_bytes)

        verify_shipped_model(APP_ASSET)
        size_mb = APP_ASSET.stat().st_size / 1e6
        print(f"wrote {APP_ASSET}  ({size_mb:.0f} MB)  dynamic-range int8")


if __name__ == "__main__":
    main()
