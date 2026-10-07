import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/services/auth/attestation_service.dart';
import 'package:pawlet/services/llm/llm_provider.dart';
import 'package:pawlet/services/llm/pawlet_proxy_provider.dart';

class _FakeAttestation implements AttestationService {
  int minted = 0;
  bool rejected = false;
  AttestationException? error;

  @override
  String get apiBase => 'https://api.test';

  @override
  Future<String> token({bool forceRefresh = false}) async {
    if (error != null) throw error!;
    if (forceRefresh || minted == 0) minted++;
    return 'jwt$minted';
  }

  @override
  Future<void> warmUp() async {}

  @override
  Future<void> reportRejected() async => rejected = true;

  @override
  void close() {}
}

const _transaction =
    '{"category":"transaction","transaction":{"balance":"2000","amount":"50",'
    '"original_amount":"50","transaction_type":"expense",'
    '"original_currency":"BDT"},"bill":null}';

void main() {
  late _FakeAttestation attestation;
  late List<http.Request> requests;

  setUp(() {
    attestation = _FakeAttestation();
    requests = [];
  });

  PawletProxyProvider proxy(List<http.Response> responses) {
    var i = 0;
    return PawletProxyProvider(
      apiBase: 'https://api.test',
      attestation: attestation,
      client: MockClient((req) async {
        requests.add(req);
        return responses[i++];
      }),
    );
  }

  Future<ClassifyResult> run(PawletProxyProvider p) =>
      p.classifyAndExtract(content: 'debit 50', sender: 'EBL', currency: 'BDT');

  Matcher fails({required bool retryable}) => throwsA(
    isA<LlmException>().having((e) => e.retryable, 'retryable', retryable),
  );

  test(
    'posts the message with the session token and parses the result',
    () async {
      final r = await run(proxy([http.Response(_transaction, 200)]));

      expect(r.category, SmsCategory.transaction);
      expect(r.transaction!.amount, '50');
      expect(r.transaction!.balance, '2000');

      final req = requests.single;
      expect(req.url.toString(), 'https://api.test/v1/classify');
      expect(req.headers['Authorization'], 'Bearer jwt1');
      expect(jsonDecode(req.body), {
        'sender': 'EBL',
        'content': 'debit 50',
        'currency': 'BDT',
      });
    },
  );

  test('a null category is none', () async {
    final r = await run(
      proxy([
        http.Response('{"category":null,"transaction":null,"bill":null}', 200),
      ]),
    );
    expect(r.category, SmsCategory.none);
  });

  test('parses a bill', () async {
    final r = await run(
      proxy([
        http.Response(
          '{"category":"bill","transaction":null,"bill":{'
          '"normalized_total_due":"8020","original_amount":"8020",'
          '"original_currency":"BDT","statement_month":7,'
          '"statement_year":2026}}',
          200,
        ),
      ]),
    );
    expect(r.category, SmsCategory.bill);
    expect(r.bill!.normalizedTotalDue, '8020');
    expect(r.bill!.statementMonth, 7);
  });

  test('a 401 re-attests once and retries with the new token', () async {
    final r = await run(
      proxy([http.Response('', 401), http.Response(_transaction, 200)]),
    );
    expect(r.category, SmsCategory.transaction);
    expect(requests.map((r) => r.headers['Authorization']), [
      'Bearer jwt1',
      'Bearer jwt2',
    ]);
  });

  test('a second 401 is fatal', () async {
    await expectLater(
      run(proxy([http.Response('', 401), http.Response('', 401)])),
      fails(retryable: false),
    );
    expect(requests, hasLength(2));
  });

  test('a 403 is fatal and reports the rejection', () async {
    await expectLater(
      run(proxy([http.Response('{"error":"banned"}', 403)])),
      fails(retryable: false),
    );
    expect(attestation.rejected, isTrue);
  });

  test('a 400 bad_request is fatal and includes the error code', () async {
    await expectLater(
      run(proxy([http.Response('{"error":"bad_request"}', 400)])),
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.message, 'message', 'HTTP 400 bad_request'),
      ),
    );
  });

  test('a 400 upstream_rejected is retryable', () async {
    await expectLater(
      run(proxy([http.Response('{"error":"upstream_rejected"}', 400)])),
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', 'HTTP 400 upstream_rejected'),
      ),
    );
  });

  test('a 408 is retryable', () async {
    await expectLater(
      run(proxy([http.Response('', 408)])),
      fails(retryable: true),
    );
  });

  test('a 429 is retryable and carries the retry hints', () async {
    await expectLater(
      run(
        proxy([
          http.Response(
            '{"error":"rate_limited"}',
            429,
            headers: {
              'retry-after': '30',
              'x-ratelimit-reset': '1791394932980',
            },
          ),
        ]),
      ),
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, 'retryable', isTrue)
            .having(
              (e) => e.retryAfter,
              'retryAfter',
              const Duration(seconds: 30),
            )
            .having((e) => e.resetAtEpochMs, 'resetAt', 1791394932980),
      ),
    );
  });

  for (final code in [500, 502, 503]) {
    test('a $code is retryable', () async {
      await expectLater(
        run(proxy([http.Response('', code)])),
        fails(retryable: true),
      );
    });
  }

  test('a network failure is retryable', () async {
    final p = PawletProxyProvider(
      apiBase: 'https://api.test',
      attestation: attestation,
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    await expectLater(run(p), fails(retryable: true));
  });

  test('a malformed 200 is retryable', () async {
    await expectLater(
      run(proxy([http.Response('not json', 200)])),
      fails(retryable: true),
    );
  });

  test('attestation unavailable is retryable and sends nothing', () async {
    attestation.error = const AttestationException('down', ineligible: false);
    await expectLater(run(proxy([])), fails(retryable: true));
    expect(requests, isEmpty);
  });

  test(
    'attestation ineligible is still retryable, so the row stays queued',
    () async {
      attestation.error = const AttestationException('no', ineligible: true);
      await expectLater(run(proxy([])), fails(retryable: true));
    },
  );

  test('no session obtainable here asks for the foreground', () async {
    attestation.error = const AttestationException(
      'no channel',
      ineligible: false,
      needsForeground: true,
    );
    await expectLater(
      run(proxy([])),
      throwsA(
        isA<LlmException>().having(
          (e) => e.needsForeground,
          'needsForeground',
          isTrue,
        ),
      ),
    );
    expect(requests, isEmpty);
  });

  test('other attestation failures do not ask for the foreground', () async {
    attestation.error = const AttestationException('down', ineligible: false);
    await expectLater(
      run(proxy([])),
      throwsA(
        isA<LlmException>().having(
          (e) => e.needsForeground,
          'needsForeground',
          isFalse,
        ),
      ),
    );
  });

  test('content over 2048 bytes is fatal with no request sent', () async {
    // 'অ' is 3 bytes in UTF-8
    final longContent = 'অ' * 700; // 2100 bytes
    final p = proxy([]);
    await expectLater(
      p.classifyAndExtract(
        content: longContent,
        sender: 'EBL',
        currency: 'BDT',
      ),
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having(
              (e) => e.message,
              'message',
              'message too long for Pawlet\'s service',
            ),
      ),
    );
    expect(requests, isEmpty);
  });

  test('budget expiry with a hanging client is retryable', () async {
    final p = PawletProxyProvider(
      apiBase: 'https://api.test',
      attestation: attestation,
      callBudget: const Duration(milliseconds: 100),
      client: MockClient((_) async {
        await Future.delayed(const Duration(seconds: 5));
        return http.Response(_transaction, 200);
      }),
    );
    await expectLater(
      run(p),
      throwsA(
        isA<LlmException>()
            .having((e) => e.retryable, 'retryable', isTrue)
            .having((e) => e.message, 'message', 'request timed out'),
      ),
    );
  });
}
