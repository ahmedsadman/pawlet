/// Confidence gate for accepting the on-device model instead of the LLM. Both
/// the classifier confidence AND the weakest NER-span confidence (NERc) must be
/// >= this value for the local result to be used. A single constant so it can be
/// made runtime-tunable later.
const double kLocalConfidenceThreshold = 0.90;

/// Class-head id -> label. MUST match the trained fused model
/// (`model-training/models/fused/config.json` class_id2label). The int8 export
/// ships no config.json, so this ordering is authoritative in the app.
const List<String> kClassLabels = [
  'expense',
  'income',
  'transfer',
  'bill',
  'null',
];

/// NER-head id -> BIO label. MUST match the fused model's ner_id2label.
const List<String> kNerLabels = [
  'O',
  'B-AMOUNT',
  'I-AMOUNT',
  'B-BALANCE',
  'I-BALANCE',
  'B-DUE',
  'I-DUE',
  'B-PERIOD',
  'I-PERIOD',
];

/// One extracted entity span. [confidence] is the weakest token's softmax prob
/// across the span (the weakest-link measure used in training's predict.py).
/// [start]/[end] are character offsets into the original SMS content.
class LocalSpan {
  const LocalSpan({
    required this.entity,
    required this.text,
    required this.confidence,
    required this.start,
    required this.end,
  });

  /// AMOUNT | BALANCE | DUE | PERIOD
  final String entity;
  final String text;
  final double confidence;
  final int start;
  final int end;
}

/// Raw on-device prediction for one SMS: the class label + confidence and every
/// emitted entity span.
class LocalPrediction {
  const LocalPrediction({
    required this.classLabel,
    required this.classConfidence,
    required this.spans,
  });

  /// expense | income | transfer | bill | null
  final String classLabel;
  final double classConfidence;
  final List<LocalSpan> spans;
}
