import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/services/classification/classifier.dart';
import 'package:pawlet/services/classification/local_classifier.dart';
import 'package:pawlet/services/classification/local_model.dart';
import 'package:pawlet/services/llm/llm_provider.dart';

/// Records invocations and returns a canned result, so we can assert whether the
/// LLM was called and how the outcome is routed.
class _FakeLlm implements LlmProvider {
  _FakeLlm(this.result);
  final ClassifyResult result;
  int calls = 0;

  @override
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  }) async {
    calls++;
    return result;
  }
}

/// Returns a canned on-device prediction (or null to simulate an unavailable
/// model), recording whether it was consulted.
class _FakeLocal implements LocalClassifier {
  _FakeLocal(this.prediction);
  final LocalPrediction? prediction;
  int calls = 0;

  @override
  Future<LocalPrediction?> infer(String content) async {
    calls++;
    return prediction;
  }
}

LocalSpan _lspan(String ent, String text, double conf, int start) => LocalSpan(
  entity: ent,
  text: text,
  confidence: conf,
  start: start,
  end: start + text.length,
);

void main() {
  group('classifyLocal', () {
    test('no model wired: no outcome, and NOT a decline', () async {
      final llm = _FakeLlm(const ClassifyResult.none());
      final classifier = Classifier(llm);
      final local = await classifier.classifyLocal(
        content: 'debit 50 BDT',
        currency: 'BDT',
      );
      expect(local.outcome, isNull);
      // The caller stamps a permanent flag on a decline; nothing judged this.
      expect(local.declined, isFalse);
      expect(llm.calls, 0);
    });

    test('a model that returns nothing is not a decline either', () async {
      final llm = _FakeLlm(const ClassifyResult.none());
      final classifier = Classifier(llm, local: _FakeLocal(null));
      final local = await classifier.classifyLocal(
        content: 'debit 50 BDT',
        currency: 'BDT',
      );
      expect(local.outcome, isNull);
      expect(local.declined, isFalse);
      expect(llm.calls, 0);
    });

    test('a low-confidence prediction is a decline', () async {
      final llm = _FakeLlm(const ClassifyResult.none());
      final local = _FakeLocal(
        const LocalPrediction(
          classLabel: 'expense',
          classConfidence: 0.4,
          spans: [],
        ),
      );
      final classifier = Classifier(llm, local: local);
      final result = await classifier.classifyLocal(
        content: 'debit 50 BDT',
        currency: 'BDT',
      );
      expect(result.outcome, isNull);
      expect(result.declined, isTrue);
      expect(llm.calls, 0);
    });

    test(
      'resolves a confident transaction on-device, parseSource local',
      () async {
        final llm = _FakeLlm(const ClassifyResult.none());
        const content = 'debit 50 BDT';
        final local = _FakeLocal(
          LocalPrediction(
            classLabel: 'expense',
            classConfidence: 0.95,
            spans: [_lspan('AMOUNT', '50', 0.97, content.indexOf('50'))],
          ),
        );
        final classifier = Classifier(llm, local: local);
        final result = await classifier.classifyLocal(
          content: content,
          currency: 'BDT',
        );
        final outcome = result.outcome;
        expect(outcome, isNotNull);
        expect(result.declined, isFalse);
        expect(outcome!.parseSource, ParseSource.local);
        expect(outcome.category, SmsCategory.transaction);
        expect(outcome.transaction!.amount, '50');
        expect(llm.calls, 0);
      },
    );

    test('resolves a confident null class as SmsCategory.none', () async {
      final llm = _FakeLlm(const ClassifyResult.none());
      final local = _FakeLocal(
        const LocalPrediction(
          classLabel: 'null',
          classConfidence: 0.98,
          spans: [],
        ),
      );
      final classifier = Classifier(llm, local: local);
      final result = await classifier.classifyLocal(
        content: 'Your OTP is 1234',
        currency: 'BDT',
      );
      final outcome = result.outcome;
      expect(outcome, isNotNull);
      expect(outcome!.category, SmsCategory.none);
      expect(outcome.parseSource, ParseSource.local);
      expect(llm.calls, 0);
    });
  });

  group('classifyRemote', () {
    test('routes a transaction and stamps parseSource', () async {
      final llm = _FakeLlm(
        const ClassifyResult(
          category: SmsCategory.transaction,
          transaction: MetadataResult(amount: '50'),
        ),
      );
      final classifier = Classifier(llm);
      final outcome = await classifier.classifyRemote(
        sender: 'MTB',
        content: 'debit 50 BDT',
        currency: 'BDT',
      );
      expect(llm.calls, 1);
      expect(outcome.parseSource, ParseSource.llm);
      expect(outcome.category, SmsCategory.transaction);
      expect(outcome.transaction!.amount, '50');
    });

    test('routes a bill', () async {
      final llm = _FakeLlm(
        const ClassifyResult(
          category: SmsCategory.bill,
          bill: BillMetadataResult(normalizedTotalDue: '8020'),
        ),
      );
      final classifier = Classifier(llm);
      final outcome = await classifier.classifyRemote(
        sender: 'EBL',
        content: 'Monthly bill',
        currency: 'BDT',
      );
      expect(outcome.category, SmsCategory.bill);
      expect(outcome.bill!.normalizedTotalDue, '8020');
      expect(outcome.parseSource, ParseSource.llm);
    });

    test('a remote none still reports parseSource llm', () async {
      final llm = _FakeLlm(const ClassifyResult.none());
      final classifier = Classifier(llm);
      final outcome = await classifier.classifyRemote(
        sender: 'MTB',
        content: 'some bank notice',
        currency: 'BDT',
      );
      expect(llm.calls, 1);
      expect(outcome.category, SmsCategory.none);
      expect(outcome.parseSource, ParseSource.llm);
    });
  });
}
