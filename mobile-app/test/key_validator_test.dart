import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/services/llm/key_validator.dart';

class _MockClient extends Mock implements http.Client {}

void main() {
  setUpAll(() => registerFallbackValue(Uri.parse('https://example.com')));

  Future<KeyCheck> run(
    Future<http.Response> Function() respond, {
    String key = 'sk-or-test',
  }) {
    final client = _MockClient();
    when(
      () => client.get(any(), headers: any(named: 'headers')),
    ).thenAnswer((_) => respond());
    return OpenRouterKeyValidator(client: client).check(key);
  }

  test('200 means the key works', () async {
    expect(
      await run(() async => http.Response('{"data":{}}', 200)),
      KeyCheck.valid,
    );
  });

  test('401 means the key is wrong', () async {
    expect(await run(() async => http.Response('nope', 401)), KeyCheck.invalid);
  });

  test('403 also means the key is wrong', () async {
    expect(await run(() async => http.Response('nope', 403)), KeyCheck.invalid);
  });

  test('a 5xx says nothing about the key', () async {
    // Reported as unreachable so the user is not told their key is bad when
    // OpenRouter is simply down.
    expect(await run(() async => http.Response('', 503)), KeyCheck.unreachable);
  });

  test('429 says nothing about the key either', () async {
    expect(await run(() async => http.Response('', 429)), KeyCheck.unreachable);
  });

  test('a network error is unreachable, not invalid', () async {
    expect(
      await run(() async => throw http.ClientException('no route')),
      KeyCheck.unreachable,
    );
  });

  test('a timeout is unreachable', () async {
    expect(
      await run(() async => throw TimeoutException('slow')),
      KeyCheck.unreachable,
    );
  });

  test('an empty key is rejected without a request', () async {
    final client = _MockClient();
    expect(
      await OpenRouterKeyValidator(client: client).check('   '),
      KeyCheck.invalid,
    );
    verifyNever(() => client.get(any(), headers: any(named: 'headers')));
  });

  test('the key is sent as a bearer token, trimmed', () async {
    final client = _MockClient();
    when(
      () => client.get(any(), headers: any(named: 'headers')),
    ).thenAnswer((_) async => http.Response('{}', 200));

    await OpenRouterKeyValidator(client: client).check('  sk-or-pad  ');

    final captured = verify(
      () => client.get(captureAny(), headers: captureAny(named: 'headers')),
    ).captured;
    expect(captured[0], Uri.parse(OpenRouterKeyValidator.endpoint));
    expect(
      (captured[1] as Map<String, String>)['Authorization'],
      'Bearer sk-or-pad',
    );
  });
}
