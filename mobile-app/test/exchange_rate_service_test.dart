import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/services/exchange_rate_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends Mock implements http.Client {}

class _FakeUri extends Fake implements Uri {}

void main() {
  final endpoint = Uri.parse('https://open.er-api.com/v6/latest/USD');

  setUpAll(() => registerFallbackValue(_FakeUri()));

  Future<SharedPreferences> prefs([Map<String, Object> seed = const {}]) async {
    SharedPreferences.setMockInitialValues(seed);
    return SharedPreferences.getInstance();
  }

  http.Response ok(double bdt) =>
      http.Response('{"result":"success","rates":{"BDT":$bdt,"USD":1}}', 200);

  test('fetches, returns, and caches the rate on first call', () async {
    final client = _MockClient();
    when(() => client.get(any())).thenAnswer((_) async => ok(120.5));
    final sp = await prefs();
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => 1000,
      endpoint: endpoint,
    );

    final rate = await svc.usdToBdt();

    expect(rate, Decimal.parse('120.5'));
    verify(() => client.get(endpoint)).called(1);
    // Cached for next time.
    expect(sp.getDouble('fx_usd_bdt_rate'), 120.5);
    expect(sp.getInt('fx_usd_bdt_fetched_at'), 1000);
  });

  test('serves fresh cache without hitting the network', () async {
    final client = _MockClient();
    final sp = await prefs({
      'fx_usd_bdt_rate': 118.0,
      'fx_usd_bdt_fetched_at': 5000,
    });
    final svc = ExchangeRateService(
      sp,
      client: client,
      // 1h later — still inside the 24h TTL.
      nowMs: () => 5000 + Duration(hours: 1).inMilliseconds,
      endpoint: endpoint,
    );

    final rate = await svc.usdToBdt();

    expect(rate, Decimal.parse('118'));
    verifyNever(() => client.get(any()));
  });

  test('refetches when the cache is stale (>24h)', () async {
    final client = _MockClient();
    when(() => client.get(any())).thenAnswer((_) async => ok(121.0));
    final sp = await prefs({
      'fx_usd_bdt_rate': 118.0,
      'fx_usd_bdt_fetched_at': 0,
    });
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => Duration(hours: 25).inMilliseconds,
      endpoint: endpoint,
    );

    final rate = await svc.usdToBdt();

    expect(rate, Decimal.parse('121'));
    verify(() => client.get(endpoint)).called(1);
  });

  test('falls back to stale cache when the fetch fails', () async {
    final client = _MockClient();
    when(() => client.get(any())).thenThrow(Exception('offline'));
    final sp = await prefs({
      'fx_usd_bdt_rate': 118.0,
      'fx_usd_bdt_fetched_at': 0,
    });
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => Duration(hours: 48).inMilliseconds,
      endpoint: endpoint,
    );

    final rate = await svc.usdToBdt();

    expect(rate, Decimal.parse('118')); // stale, but usable
  });

  test('returns null when never cached and the fetch fails', () async {
    final client = _MockClient();
    when(() => client.get(any())).thenThrow(Exception('offline'));
    final sp = await prefs();
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => 1000,
      endpoint: endpoint,
    );

    expect(await svc.usdToBdt(), isNull);
  });

  test('ignores a non-success payload and returns null (no cache)', () async {
    final client = _MockClient();
    when(
      () => client.get(any()),
    ).thenAnswer((_) async => http.Response('{"result":"error"}', 200));
    final sp = await prefs();
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => 1000,
      endpoint: endpoint,
    );

    expect(await svc.usdToBdt(), isNull);
  });

  test('ignores a non-200 status and returns null (no cache)', () async {
    final client = _MockClient();
    when(
      () => client.get(any()),
    ).thenAnswer((_) async => http.Response('{"result":"success"}', 503));
    final sp = await prefs();
    final svc = ExchangeRateService(
      sp,
      client: client,
      nowMs: () => 1000,
      endpoint: endpoint,
    );

    expect(await svc.usdToBdt(), isNull);
  });
}
