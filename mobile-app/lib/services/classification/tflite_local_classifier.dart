import 'dart:async';
import 'dart:math' as math;

import 'package:dart_bert_tokenizer/dart_bert_tokenizer.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'local_classifier.dart';
import 'local_model.dart';

/// [LocalClassifier] backed by the bundled fused TFLite model + the HF WordPiece
/// tokenizer, run via the tflite_flutter (LiteRT) interpreter.
///
/// Inference runs in a background isolate ([IsolateInterpreter]) so the ~99 MB
/// model's `run()` never blocks the UI isolate that drives the processing queue.
/// Inputs are padded to a FIXED [_maxLen] so `allocateTensors` runs once at load
/// (not per message) — the per-call resize/realloc on the big graph was itself a
/// source of jank. The interpreter + tokenizer load lazily once and are reused;
/// a load failure is remembered so later messages skip to the LLM fallback.
class TfliteLocalClassifier implements LocalClassifier {
  TfliteLocalClassifier({
    this.modelAsset = 'assets/model/model.tflite',
    this.tokenizerAsset = 'assets/model/tokenizer.json',
  });

  final String modelAsset;
  final String tokenizerAsset;

  /// Must match model-training config.MAX_LEN.
  static const int _maxLen = 128;
  static const int _numNerLabels = 9; // kNerLabels.length

  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;
  WordPieceTokenizer? _tokenizer;
  // Input tensor indices, resolved by name (onnx2tf preserves the ONNX names but
  // not necessarily their positional order).
  late int _idsIn;
  late int _maskIn;
  late int _typeIn;
  // Output tensor indices (position in getOutputTensors()), resolved by name.
  late int _classOut;
  late int _nerOut;
  bool _initFailed = false;

  Future<bool> _ensureLoaded() async {
    if (_interpreter != null && _isolate != null && _tokenizer != null) {
      return true;
    }
    if (_initFailed) return false;
    try {
      final json = await rootBundle.loadString(tokenizerAsset);
      _tokenizer = WordPieceTokenizer.fromTokenizerJsonString(json);
      final interpreter = await Interpreter.fromAsset(modelAsset);

      final ins = interpreter.getInputTensors();
      _idsIn = ins.indexWhere((t) => t.name.contains('input_ids'));
      _maskIn = ins.indexWhere((t) => t.name.contains('attention_mask'));
      _typeIn = ins.indexWhere((t) => t.name.contains('token_type_ids'));

      final outs = interpreter.getOutputTensors();
      _classOut = outs.indexWhere((t) => t.name.contains('class_logits'));
      _nerOut = outs.indexWhere((t) => t.name.contains('ner_logits'));

      if ([_idsIn, _maskIn, _typeIn, _classOut, _nerOut].contains(-1)) {
        _initFailed = true;
        interpreter.close();
        return false;
      }

      // Fix the sequence length once so the tensor arena is allocated a single
      // time here, not on every inference.
      interpreter.resizeInputTensor(_idsIn, [1, _maxLen]);
      interpreter.resizeInputTensor(_maskIn, [1, _maxLen]);
      interpreter.resizeInputTensor(_typeIn, [1, _maxLen]);
      interpreter.allocateTensors();

      // Run inference in a background isolate so the native run() never blocks
      // the UI isolate that drives the processing queue.
      _isolate = await IsolateInterpreter.create(address: interpreter.address);
      _interpreter = interpreter;
      return true;
    } catch (_) {
      _initFailed = true;
      return false;
    }
  }

  @override
  Future<LocalPrediction?> infer(String content) async {
    if (!await _ensureLoaded()) return null;
    final tokenizer = _tokenizer!;
    final isolate = _isolate!;

    try {
      final enc = tokenizer.encode(content);
      final n = math.min(enc.ids.length, _maxLen);

      // Fixed-length, padded inputs (arena allocated once at load). Plain Dart int
      // lists: the model takes int32 inputs and tflite_flutter's per-element int32
      // path is little-endian correct (its int64 path is not). Padding is masked
      // out via attention_mask=0, so the result matches the unpadded sequence.
      final ids = List<int>.filled(_maxLen, 0); // 0 == [PAD]
      final mask = List<int>.filled(_maxLen, 0);
      final typeIds = List<int>.filled(_maxLen, 0);
      for (var i = 0; i < n; i++) {
        ids[i] = enc.ids[i];
        mask[i] = 1;
      }

      // runForMultipleInputs takes inputs ordered by ascending input-tensor index.
      final byIndex = <int, Object>{
        _idsIn: [ids],
        _maskIn: [mask],
        _typeIn: [typeIds],
      };
      final orderedKeys = byIndex.keys.toList()..sort();
      final inputs = [for (final k in orderedKeys) byIndex[k]!];

      // Pre-allocated output buffers matching the model's (fixed) shapes.
      final classBuf = [List<double>.filled(kClassLabels.length, 0)];
      final nerBuf = [
        [
          for (var t = 0; t < _maxLen; t++)
            List<double>.filled(_numNerLabels, 0),
        ],
      ];
      final outputs = <int, Object>{_classOut: classBuf, _nerOut: nerBuf};

      // Runs on the background isolate; awaits without blocking the UI isolate.
      await isolate.runForMultipleInputs(inputs, outputs);

      final (label, conf) = _classify(classBuf[0]);
      // Decode only the real (non-pad) tokens: enc.offsets has length n.
      final spans = _decodeSpans(content, enc, nerBuf[0], n);
      return LocalPrediction(
        classLabel: label,
        classConfidence: conf,
        spans: spans,
      );
    } catch (_) {
      return null; // any runtime failure -> LLM fallback
    }
  }

  (String, double) _classify(List<double> logits) {
    final probs = _softmax(logits);
    var best = 0;
    for (var i = 1; i < probs.length; i++) {
      if (probs[i] > probs[best]) best = i;
    }
    return (kClassLabels[best], probs[best]);
  }

  /// Decodes per-token NER logits into entity spans, mirroring
  /// model-training/src/predict.py.extract: contiguous B-/I- runs of one entity;
  /// span confidence = the weakest token's softmax prob.
  List<LocalSpan> _decodeSpans(
    String content,
    Encoding enc,
    List<List<double>> nerTokens,
    int n,
  ) {
    final spans = <LocalSpan>[];
    String? curEnt;
    int? curStart;
    int? curEnd;
    var curMin = 1.0;

    void close() {
      if (curEnt != null && curStart != null && curEnd != null) {
        spans.add(
          LocalSpan(
            entity: curEnt!,
            text: content.substring(curStart!, curEnd!),
            confidence: curMin,
            start: curStart!,
            end: curEnd!,
          ),
        );
      }
      curEnt = null;
      curStart = null;
      curEnd = null;
      curMin = 1.0;
    }

    final limit = math.min(n, nerTokens.length);
    for (var t = 0; t < limit; t++) {
      final (st, en) = enc.offsets[t];
      if (st == en) continue; // special token ([CLS]/[SEP])
      final probs = _softmax(nerTokens[t]);
      var best = 0;
      for (var j = 1; j < _numNerLabels; j++) {
        if (probs[j] > probs[best]) best = j;
      }
      final lab = kNerLabels[best];
      if (lab == 'O') {
        close();
        continue;
      }
      final dash = lab.indexOf('-');
      final pre = lab.substring(0, dash);
      final ent = lab.substring(dash + 1);
      if (pre == 'B' || curEnt == null || curEnt != ent) {
        close();
        curEnt = ent;
        curStart = st;
        curEnd = en;
        curMin = probs[best];
      } else {
        curEnd = en;
        curMin = math.min(curMin, probs[best]);
      }
    }
    close();
    return spans;
  }

  List<double> _softmax(List<double> xs) {
    final maxX = xs.reduce(math.max);
    final exps = [for (final x in xs) math.exp(x - maxX)];
    final sum = exps.reduce((a, b) => a + b);
    return [for (final e in exps) e / sum];
  }

  /// Frees the inference isolate and the native interpreter. Call from each
  /// isolate's dispose so a bundle that loaded the model doesn't leak.
  void close() {
    final iso = _isolate;
    if (iso != null) unawaited(iso.close());
    _interpreter?.close();
    _isolate = null;
    _interpreter = null;
  }
}
