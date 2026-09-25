import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/classification/local_model.dart';

void main() {
  test('label maps match the trained fused model order', () {
    expect(kClassLabels, [
      'expense',
      'income',
      'transfer',
      'bill',
      'null',
    ]);
    expect(kNerLabels, [
      'O',
      'B-AMOUNT',
      'I-AMOUNT',
      'B-BALANCE',
      'I-BALANCE',
      'B-DUE',
      'I-DUE',
      'B-PERIOD',
      'I-PERIOD',
    ]);
  });

  test('threshold is 0.90', () {
    expect(kLocalConfidenceThreshold, 0.90);
  });

  test('LocalPrediction holds class + spans', () {
    const p = LocalPrediction(
      classLabel: 'expense',
      classConfidence: 0.9,
      spans: [
        LocalSpan(
          entity: 'AMOUNT',
          text: '50',
          confidence: 0.95,
          start: 7,
          end: 9,
        ),
      ],
    );
    expect(p.classLabel, 'expense');
    expect(p.spans.single.entity, 'AMOUNT');
    expect(p.spans.single.start, 7);
  });
}
