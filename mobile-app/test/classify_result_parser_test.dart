import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/llm/classify_result_parser.dart';
import 'package:pawlet/services/llm/llm_provider.dart';

void main() {
  test('reads string-valued numbers, as the server sends them', () {
    final r = parseClassifyObject({
      'category': 'transaction',
      'transaction': {
        'balance': '2000',
        'amount': '50',
        'original_amount': '50',
        'transaction_type': 'expense',
        'original_currency': 'bdt',
      },
      'bill': null,
    });
    expect(r.category, SmsCategory.transaction);
    expect(r.transaction!.amount, '50');
    expect(r.transaction!.balance, '2000');
    expect(r.transaction!.originalCurrency, 'BDT');
  });

  test('a null category is none', () {
    final r = parseClassifyObject({
      'category': null,
      'transaction': null,
      'bill': null,
    });
    expect(r.category, SmsCategory.none);
  });

  test('an unknown category is a retryable failure', () {
    expect(
      () => parseClassifyObject({'category': 'promo'}),
      throwsA(
        isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
      ),
    );
  });

  test('Retry-After takes integer seconds only', () {
    expect(parseRetryAfter('30'), const Duration(seconds: 30));
    expect(parseRetryAfter('-1'), isNull);
    expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    expect(parseRetryAfter(null), isNull);
  });

  test('X-RateLimit-Reset is carried as epoch milliseconds', () {
    expect(parseResetAt('1791394932980'), 1791394932980);
    expect(parseResetAt('x'), isNull);
  });
}
