import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_bert_tokenizer/dart_bert_tokenizer.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'local_classifier.dart';
import 'local_model.dart';

/// [LocalClassifier] backed by the bundled int8 fused ONNX model + the HF
/// WordPiece tokenizer. The session and tokenizer are loaded lazily once and
/// reused; a load failure is remembered so later messages skip straight to the
/// LLM fallback without re-attempting.
class OnnxLocalClassifier implements LocalClassifier {
  OnnxLocalClassifier({
    this.modelAsset = 'assets/model/model.onnx',
    this.tokenizerAsset = 'assets/model/tokenizer.json',
  });

  final String modelAsset;
  final String tokenizerAsset;

  /// Must match model-training config.MAX_LEN.
  static const int _maxLen = 128;
  static const int _numNerLabels = 9; // kNerLabels.length

  OrtSession? _session;
  WordPieceTokenizer? _tokenizer;
  bool _initFailed = false;

  Future<bool> _ensureLoaded() async {
    if (_session != null && _tokenizer != null) return true;
    if (_initFailed) return false;
    try {
      final json = await rootBundle.loadString(tokenizerAsset);
      _tokenizer = WordPieceTokenizer.fromTokenizerJsonString(json);
      _session = await OnnxRuntime().createSessionFromAsset(modelAsset);
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
    final session = _session!;

    OrtValue? idsT;
    OrtValue? maskT;
    OrtValue? typeT;
    Map<String, OrtValue>? outputs;
    try {
      final enc = tokenizer.encode(content);
      final n = math.min(enc.ids.length, _maxLen);

      // The model was exported with int64 inputs; build Int64List explicitly so
      // OrtValue.fromList tags them int64 (a plain List<int> of small ids would
      // be inferred as int32 and the graph would reject it).
      final ids = Int64List(n);
      for (var i = 0; i < n; i++) {
        ids[i] = enc.ids[i];
      }
      final mask = Int64List(n)..fillRange(0, n, 1);
      final typeIds = Int64List(n); // single sequence -> all zeros

      idsT = await OrtValue.fromList(ids, [1, n]);
      maskT = await OrtValue.fromList(mask, [1, n]);
      typeT = await OrtValue.fromList(typeIds, [1, n]);

      outputs = await session.run({
        'input_ids': idsT,
        'attention_mask': maskT,
        'token_type_ids': typeT,
      });

      final classLogits = (await outputs['class_logits']!.asFlattenedList())
          .cast<num>();
      final nerFlat = (await outputs['ner_logits']!.asFlattenedList())
          .cast<num>();

      final (label, conf) = _classify(classLogits);
      final spans = _decodeSpans(content, enc, nerFlat, n);
      return LocalPrediction(
        classLabel: label,
        classConfidence: conf,
        spans: spans,
      );
    } catch (_) {
      return null; // any runtime failure -> LLM fallback
    } finally {
      await idsT?.dispose();
      await maskT?.dispose();
      await typeT?.dispose();
      if (outputs != null) {
        for (final v in outputs.values) {
          await v.dispose();
        }
      }
    }
  }

  (String, double) _classify(List<num> logits) {
    final probs = _softmax([for (final l in logits) l.toDouble()]);
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
    List<num> nerFlat,
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

    for (var t = 0; t < n; t++) {
      final (st, en) = enc.offsets[t];
      if (st == en) continue; // special token ([CLS]/[SEP])
      final base = t * _numNerLabels;
      final probs = _softmax([
        for (var j = 0; j < _numNerLabels; j++) nerFlat[base + j].toDouble(),
      ]);
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
}
