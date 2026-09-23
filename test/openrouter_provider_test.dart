import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meowni/services/llm/llm_provider.dart';
import 'package:meowni/services/llm/openrouter_provider.dart';
import 'package:mocktail/mocktail.dart';

class _MockClient extends Mock implements http.Client {}

/// Wraps an inner (fused) JSON string in an OpenRouter chat-completion envelope.
String _completion(String innerContent) => jsonEncode({
  'choices': [
    {
      'message': {'content': innerContent},
    },
  ],
});

OpenRouterProvider _provider(http.Client client) => OpenRouterProvider(
  apiKey: 'secret-key',
  model: 'openrouter/free',
  client: client,
);

Future<ClassifyResult> _run(http.Client client) =>
    _provider(client).classifyAndExtract(
      content: 'msg',
      sender: 'SENDER',
      currency: 'BDT',
    );

void _stubOnce(http.Client client, http.Response response) {
  when(
    () => client.post(
      any(),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    ),
  ).thenAnswer((_) async => response);
}

void _verifyCalls(http.Client client, int n) {
  verify(
    () => client.post(
      any(),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    ),
  ).called(n);
}

void main() {
  setUpAll(() => registerFallbackValue(Uri.parse('https://openrouter.ai')));

  late _MockClient client;
  setUp(() => client = _MockClient());

  group('parsing', () {
    test('parses a transaction (no bank field)', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"transaction","transaction":{'
            '"balance":2000,"amount":50.0,"original_amount":50.0,'
            '"transaction_type":"expense","original_currency":"bdt"},"bill":null}',
          ),
          200,
        ),
      );

      final r = await _run(client);
      expect(r.category, SmsCategory.transaction);
      final tx = r.transaction!;
      expect(tx.balance, '2000');
      expect(tx.amount, '50.0');
      expect(tx.transactionType, 'expense');
      expect(tx.originalCurrency, 'BDT'); // upper-cased
    });

    test('parses a bill with statement period', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"bill","transaction":null,"bill":{'
            '"normalized_total_due":8020.0,"original_amount":8020.0,'
            '"original_currency":"BDT","statement_month":7,"statement_year":2026}}',
          ),
          200,
        ),
      );

      final bill = (await _run(client)).bill!;
      expect(bill.normalizedTotalDue, '8020.0');
      expect(bill.statementMonth, 7);
      expect(bill.statementYear, 2026);
    });

    test('maps a null category to none', () async {
      _stubOnce(
        client,
        http.Response(
          _completion('{"category":null,"transaction":null,"bill":null}'),
          200,
        ),
      );
      final r = await _run(client);
      expect(r.category, SmsCategory.none);
      expect(r.transaction, isNull);
      expect(r.bill, isNull);
    });

    test('parses content wrapped in a ```json fence', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '```json\n{"category":null,"transaction":null,"bill":null}\n```',
          ),
          200,
        ),
      );
      expect((await _run(client)).category, SmsCategory.none);
    });
  });

  group('validation', () {
    test('nulls the amount trio when transaction_type is missing', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"transaction","transaction":{'
            '"balance":100,"amount":50,"original_amount":50,'
            '"transaction_type":null,"original_currency":"BDT"},"bill":null}',
          ),
          200,
        ),
      );
      final tx = (await _run(client)).transaction!;
      expect(tx.amount, isNull);
      expect(tx.originalAmount, isNull);
      expect(tx.transactionType, isNull);
      expect(tx.balance, '100'); // balance is independent of the amount trio
    });

    test('keeps balance + currency when only a balance is present', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"transaction","transaction":{'
            '"balance":999,"amount":null,"original_amount":null,'
            '"transaction_type":null,"original_currency":"BDT"},"bill":null}',
          ),
          200,
        ),
      );
      final tx = (await _run(client)).transaction!;
      expect(tx.balance, '999');
      expect(tx.amount, isNull);
      expect(tx.originalCurrency, 'BDT'); // a number (balance) is present
    });

    test('drops currency when neither amount nor balance is present', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"transaction","transaction":{'
            '"balance":null,"amount":null,"original_amount":null,'
            '"transaction_type":null,"original_currency":"BDT"},"bill":null}',
          ),
          200,
        ),
      );
      final tx = (await _run(client)).transaction!;
      expect(tx.balance, isNull);
      expect(tx.originalCurrency, isNull);
    });

    test('rejects out-of-range month/year but keeps a valid bill total', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"bill","transaction":null,"bill":{'
            '"normalized_total_due":100,"original_amount":100,'
            '"original_currency":"BDT","statement_month":13,"statement_year":1999}}',
          ),
          200,
        ),
      );
      final bill = (await _run(client)).bill!;
      expect(bill.normalizedTotalDue, '100');
      expect(bill.originalCurrency, 'BDT');
      expect(bill.statementMonth, isNull); // 13 out of range
      expect(bill.statementYear, isNull); // 1999 out of range
    });

    test('nulls the bill money trio when the currency is invalid', () async {
      _stubOnce(
        client,
        http.Response(
          _completion(
            '{"category":"bill","transaction":null,"bill":{'
            '"normalized_total_due":100,"original_amount":100,'
            '"original_currency":"dollars","statement_month":7,"statement_year":2026}}',
          ),
          200,
        ),
      );
      final bill = (await _run(client)).bill!;
      expect(bill.normalizedTotalDue, isNull); // trio nulled together
      expect(bill.originalAmount, isNull);
      expect(bill.originalCurrency, isNull);
      expect(bill.statementMonth, 7); // period stays independent
    });
  });

  group('request', () {
    test('sends model, JSON response_format, bearer key and both messages', () async {
      _stubOnce(
        client,
        http.Response(
          _completion('{"category":null,"transaction":null,"bill":null}'),
          200,
        ),
      );
      await _provider(client).classifyAndExtract(
        content: 'debit 50',
        sender: 'BRACBANK',
        currency: 'BDT',
      );

      final captured = verify(
        () => client.post(
          captureAny(),
          headers: captureAny(named: 'headers'),
          body: captureAny(named: 'body'),
        ),
      ).captured;
      final uri = captured[0] as Uri;
      final headers = captured[1] as Map<String, String>;
      final body = jsonDecode(captured[2] as String) as Map<String, dynamic>;

      expect(uri.toString(), OpenRouterProvider.endpoint);
      expect(headers['Authorization'], 'Bearer secret-key');
      expect(body['model'], 'openrouter/free');
      expect(body['response_format'], {'type': 'json_object'});
      final messages = body['messages'] as List;
      expect(messages.first['role'], 'system');
      expect(messages.last['role'], 'user');
      final userContent = messages.last['content'] as String;
      expect(userContent, contains('BDT'));
      expect(userContent, contains('BRACBANK'));
      expect(userContent, contains('debit 50'));
    });
  });

  // The provider makes a SINGLE attempt and does not retry internally; transient
  // failures surface as retryable LlmExceptions and the processing pipeline owns
  // retry/backoff (see processing_service_test). Every case below makes 1 call.
  group('error classification (single attempt)', () {
    test('429 rate-limit → retryable', () async {
      _stubOnce(client, http.Response('rate limited', 429));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('5xx server error → retryable', () async {
      _stubOnce(client, http.Response('server error', 503));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('408 request timeout → retryable', () async {
      _stubOnce(client, http.Response('timeout', 408));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('TimeoutException → retryable', () async {
      when(
        () => client.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => throw TimeoutException('slow'));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('network error → retryable', () async {
      when(
        () => client.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => throw Exception('connection reset'));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('401 → fatal (not retryable)', () async {
      _stubOnce(client, http.Response('unauthorized', 401));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('empty choices → retryable', () async {
      _stubOnce(client, http.Response(jsonEncode({'choices': []}), 200));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('content that is valid JSON but not an object → retryable', () async {
      _stubOnce(client, http.Response(_completion('[]'), 200));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('malformed content → retryable', () async {
      _stubOnce(client, http.Response(_completion('not json at all'), 200));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('unexpected category value → retryable (not silently ignored)', () async {
      _stubOnce(
        client,
        http.Response(
          _completion('{"category":"txn","transaction":null,"bill":null}'),
          200,
        ),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
      _verifyCalls(client, 1);
    });
  });

  // Server-supplied retry hints on 429/503. OpenRouter sends exactly one of
  // Retry-After (relative delta-seconds) or X-RateLimit-Reset (absolute epoch)
  // per response; the provider parses both clock-free and carries them on the
  // thrown LlmException. Reset is normalized to epoch-milliseconds.
  group('retry hints', () {
    test('Retry-After delta-seconds → retryAfter, no reset', () async {
      _stubOnce(client, http.Response('rate', 429, headers: {'retry-after': '30'}));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))
              .having((e) => e.resetAtEpochMs, 'resetAtEpochMs', isNull),
        ),
      );
      _verifyCalls(client, 1);
    });

    test('X-RateLimit-Reset epoch seconds → normalized to ms', () async {
      _stubOnce(
        client,
        http.Response('rate', 429, headers: {'x-ratelimit-reset': '1758000000'}),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.resetAtEpochMs, 'resetAtEpochMs', 1758000000000)
              .having((e) => e.retryAfter, 'retryAfter', isNull),
        ),
      );
    });

    test('X-RateLimit-Reset epoch ms → used as-is', () async {
      _stubOnce(
        client,
        http.Response('rate', 429, headers: {'x-ratelimit-reset': '1758000000000'}),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.resetAtEpochMs, 'resetAtEpochMs', 1758000000000),
        ),
      );
    });

    test('both headers → both fields set', () async {
      _stubOnce(
        client,
        http.Response('rate', 429, headers: {
          'retry-after': '30',
          'x-ratelimit-reset': '1758000000',
        }),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 30))
              .having((e) => e.resetAtEpochMs, 'resetAtEpochMs', 1758000000000),
        ),
      );
    });

    test('no hint headers → both null', () async {
      _stubOnce(client, http.Response('rate', 429));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.retryAfter, 'retryAfter', isNull)
              .having((e) => e.resetAtEpochMs, 'resetAtEpochMs', isNull),
        ),
      );
    });

    test('HTTP-date Retry-After → null (out of scope, no clock)', () async {
      _stubOnce(
        client,
        http.Response('rate', 429,
            headers: {'retry-after': 'Wed, 21 Oct 2026 07:28:00 GMT'}),
      );
      await expectLater(
        _run(client),
        throwsA(isA<LlmException>().having((e) => e.retryAfter, 'retryAfter', isNull)),
      );
    });

    test('negative Retry-After → null', () async {
      _stubOnce(client, http.Response('rate', 429, headers: {'retry-after': '-5'}));
      await expectLater(
        _run(client),
        throwsA(isA<LlmException>().having((e) => e.retryAfter, 'retryAfter', isNull)),
      );
    });

    test('non-integer X-RateLimit-Reset → null', () async {
      _stubOnce(
        client,
        http.Response('rate', 429, headers: {'x-ratelimit-reset': 'soon'}),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.resetAtEpochMs, 'resetAtEpochMs', isNull),
        ),
      );
    });

    test('negative X-RateLimit-Reset → null', () async {
      _stubOnce(
        client,
        http.Response('rate', 429, headers: {'x-ratelimit-reset': '-100'}),
      );
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>().having((e) => e.resetAtEpochMs, 'resetAtEpochMs', isNull),
        ),
      );
    });

    test('503 Retry-After → parsed on any retryable status', () async {
      _stubOnce(client, http.Response('busy', 503, headers: {'retry-after': '10'}));
      await expectLater(
        _run(client),
        throwsA(
          isA<LlmException>()
              .having((e) => e.retryAfter, 'retryAfter', const Duration(seconds: 10)),
        ),
      );
    });
  });
}
