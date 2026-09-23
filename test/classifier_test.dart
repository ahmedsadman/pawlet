import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/services/classification/classifier.dart';
import 'package:meowni/services/llm/llm_provider.dart';

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
}
