import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pawlet/services/classification/tflite_local_classifier.dart';

/// On-device parity: the bundled int8 model + Dart tokenizer must reproduce the
/// Python model's decisions. Runs on a connected arm64 device/emulator (the
/// native ONNX Runtime library is unavailable in the host `flutter test` VM).
///
/// Expectations mirror model-training/scripts/gen_parity_fixtures.py output; they
/// are inlined (rather than loaded from the test fixture JSON) so no test-only
/// asset needs shipping in the app bundle. int8 quantization can nudge borderline
/// low-confidence spans, so span checks assert the strong expected entities are
/// present rather than exact-set equality.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const cases = <({String text, String label, Set<String> mustHaveSpans})>[
    (
      text: 'Your A/C debited by Tk 500.00. Balance Tk 1,200.50 on 12-05-24.',
      label: 'expense',
      mustHaveSpans: {'AMOUNT:500.00', 'BALANCE:1,200.50'},
    ),
    (
      text:
          'You have received BDT 3,000 from John. Available balance BDT 8,500.',
      label: 'income',
      mustHaveSpans: {'AMOUNT:3,000', 'BALANCE:8,500'},
    ),
    (
      text:
          'Monthly bill 423800******3241 AUG2026; Total Due: BDT 4924.35, '
          'Min Due: BDT 4833.35',
      label: 'bill',
      mustHaveSpans: {'DUE:4924.35', 'PERIOD:AUG2026'},
    ),
    (
      text:
          'Your bill for card 498851******3711 for JUL 2026 BDT 4111.79 '
          'Min due: BDT 500',
      label: 'bill',
      mustHaveSpans: {'DUE:4111.79', 'PERIOD:JUL 2026'},
    ),
    (
      text: 'OTP 123456. Do not share with anyone.',
      label: 'null',
      mustHaveSpans: <String>{},
    ),
  ];

  testWidgets('on-device model reproduces the Python decisions', (
    tester,
  ) async {
    final classifier = TfliteLocalClassifier();
    for (final c in cases) {
      final pred = await classifier.infer(c.text);
      expect(
        pred,
        isNotNull,
        reason: 'model failed to load/run for: ${c.text}',
      );
      expect(
        pred!.classLabel,
        c.label,
        reason: 'class label mismatch for: ${c.text}',
      );
      final got = pred.spans.map((s) => '${s.entity}:${s.text}').toSet();
      expect(
        got.containsAll(c.mustHaveSpans),
        isTrue,
        reason: 'spans $got missing some of ${c.mustHaveSpans} for: ${c.text}',
      );
    }
  });
}
