import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/bank.dart';
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

Bank _bank(
  String name, {
  String accountType = 'deposit',
  List<String> matchers = const [],
  String? cardDigits,
}) => Bank(
  id: name.hashCode,
  name: name,
  accountType: accountType,
  cardDigits: cardDigits,
  matchers: matchers,
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  final mtb = _bank('Mutual Trust Bank', matchers: const ['mtb']);
  final ebl = _bank(
    'EBL Credit Card',
    accountType: 'credit',
    cardDigits: '4238|3241',
    matchers: const ['ebl'],
  );
  final banks = [mtb, ebl];

  Future<ClassificationOutcome> run(
    _FakeLlm llm,
    String sender,
    String content,
  ) => Classifier(
    llm,
  ).classify(sender: sender, content: content, banks: banks, currency: 'BDT');

  test('Layer-1 miss → ignored, no LLM call', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    final outcome = await run(llm, 'Daraz', 'win a prize');
    expect(outcome.category, SmsCategory.none);
    expect(outcome.llmInvoked, isFalse);
    expect(llm.calls, 0);
  });

  test('sender match → one LLM call, transaction routed', () async {
    final llm = _FakeLlm(
      const ClassifyResult(
        category: SmsCategory.transaction,
        transaction: MetadataResult(amount: '50'),
      ),
    );
    final outcome = await run(llm, 'MTB', 'debit 50 BDT');
    expect(llm.calls, 1);
    expect(outcome.llmInvoked, isTrue);
    expect(outcome.category, SmsCategory.transaction);
    expect(outcome.transaction!.amount, '50');
  });

  test('card-digit match gates in even when the sender does not', () async {
    final llm = _FakeLlm(
      const ClassifyResult(
        category: SmsCategory.bill,
        bill: BillMetadataResult(normalizedTotalDue: '8020'),
      ),
    );
    final outcome = await run(llm, 'RANDOM', 'Monthly bill 4238****3241');
    expect(llm.calls, 1);
    expect(outcome.category, SmsCategory.bill);
    expect(outcome.bill!.normalizedTotalDue, '8020');
  });

  test('LLM returns none → outcome none but llmInvoked true', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    final outcome = await run(llm, 'MTB', 'some bank notice');
    expect(llm.calls, 1);
    expect(outcome.llmInvoked, isTrue);
    expect(outcome.category, SmsCategory.none);
  });

  test('confident local transaction skips the LLM', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    const content = 'debit 50 BDT';
    final local = _FakeLocal(
      LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.95,
        spans: [_lspan('AMOUNT', '50', 0.97, content.indexOf('50'))],
      ),
    );
    final outcome = await Classifier(llm, local: local).classify(
      sender: 'MTB',
      content: content,
      banks: banks,
      currency: 'BDT',
    );
    expect(local.calls, 1);
    expect(llm.calls, 0);
    expect(outcome.llmInvoked, isFalse);
    expect(outcome.parseSource, ParseSource.local);
    expect(outcome.category, SmsCategory.transaction);
    expect(outcome.transaction!.amount, '50');
  });

  test('low-confidence local prediction falls back to the LLM', () async {
    final llm = _FakeLlm(
      const ClassifyResult(
        category: SmsCategory.transaction,
        transaction: MetadataResult(
          amount: '50',
          originalAmount: '50',
          transactionType: 'expense',
          originalCurrency: 'BDT',
        ),
      ),
    );
    final local = _FakeLocal(
      const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.4,
        spans: [],
      ),
    );
    final outcome = await Classifier(llm, local: local).classify(
      sender: 'MTB',
      content: 'debit 50 BDT',
      banks: banks,
      currency: 'BDT',
    );
    expect(local.calls, 1);
    expect(llm.calls, 1);
    expect(outcome.llmInvoked, isTrue);
    expect(outcome.parseSource, ParseSource.llm);
  });

  test('local returns null (model unavailable) -> LLM fallback', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    final local = _FakeLocal(null);
    final outcome = await Classifier(llm, local: local).classify(
      sender: 'MTB',
      content: 'debit 50 BDT',
      banks: banks,
      currency: 'BDT',
    );
    expect(llm.calls, 1);
    expect(outcome.parseSource, ParseSource.llm);
  });

  test('confident local null is ignored without an LLM call', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    final local = _FakeLocal(
      const LocalPrediction(
        classLabel: 'null',
        classConfidence: 0.98,
        spans: [],
      ),
    );
    final outcome = await Classifier(llm, local: local).classify(
      sender: 'MTB',
      content: 'Your OTP is 1234',
      banks: banks,
      currency: 'BDT',
    );
    expect(llm.calls, 0);
    expect(outcome.category, SmsCategory.none);
    expect(outcome.llmInvoked, isFalse);
    expect(outcome.parseSource, ParseSource.local);
  });

  test('gate miss is ignored with no local or LLM call', () async {
    final llm = _FakeLlm(const ClassifyResult.none());
    final local = _FakeLocal(
      const LocalPrediction(
        classLabel: 'expense',
        classConfidence: 0.99,
        spans: [],
      ),
    );
    final outcome = await Classifier(llm, local: local).classify(
      sender: 'Daraz',
      content: 'win a prize',
      banks: banks,
      currency: 'BDT',
    );
    expect(local.calls, 0);
    expect(llm.calls, 0);
    expect(outcome.parseSource, isNull);
    expect(outcome.category, SmsCategory.none);
  });
}
