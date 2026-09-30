import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Fetches and caches the USD→BDT exchange rate from open.er-api.com (free, no
/// API key). One network call per [ttl] (24h): [usdToBdt] serves the cached rate
/// while it is fresh, fetches when it is stale, and falls back to the stale cache
/// when the network is unavailable. Returns null only when nothing has ever been
/// cached and the fetch fails.
class ExchangeRateService {
  ExchangeRateService(
    this._prefs, {
    http.Client? client,
    int Function()? nowMs,
    Uri? endpoint,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _endpoint =
           endpoint ?? Uri.parse('https://open.er-api.com/v6/latest/USD');

  final SharedPreferences _prefs;
  final http.Client _client;
  final bool _ownsClient;
  final int Function() _nowMs;
  final Uri _endpoint;

  static const String _kRate = 'fx_usd_bdt_rate'; // double
  static const String _kFetchedAt = 'fx_usd_bdt_fetched_at'; // epoch ms
  static const Duration ttl = Duration(hours: 24);
  static const Duration _timeout = Duration(seconds: 15);

  /// Closes the internally-created HTTP client. No-op when the caller injected
  /// their own (they own its lifecycle).
  void close() {
    if (_ownsClient) _client.close();
  }

  /// The cached rate, however stale, without ever attempting a fetch. Null when
  /// nothing has been cached yet.
  ///
  /// Used by the processing queue while offline: [usdToBdt] would spend its
  /// 15-second timeout on a request that cannot succeed, on a path an incoming
  /// SMS drives synchronously.
  Future<Decimal?> cachedUsdToBdt() async {
    final cached = _prefs.getDouble(_kRate);
    return cached == null ? null : _asDecimal(cached);
  }

  /// The USD→BDT rate as a [Decimal], or null when never cached and the fetch
  /// fails. A number > 0 is guaranteed when non-null.
  Future<Decimal?> usdToBdt() async {
    final cachedAt = _prefs.getInt(_kFetchedAt);
    final cached = _prefs.getDouble(_kRate);
    final fresh =
        cachedAt != null && (_nowMs() - cachedAt) < ttl.inMilliseconds;
    if (fresh && cached != null) return _asDecimal(cached);

    final fetched = await _fetch();
    if (fetched != null) {
      await _prefs.setDouble(_kRate, fetched);
      await _prefs.setInt(_kFetchedAt, _nowMs());
      return _asDecimal(fetched);
    }
    // Fetch failed (offline / server error): serve stale cache if we have any.
    return cached == null ? null : _asDecimal(cached);
  }

  Decimal _asDecimal(double v) => Decimal.parse(v.toString());

  Future<double?> _fetch() async {
    try {
      final res = await _client.get(_endpoint).timeout(_timeout);
      if (res.statusCode != 200) return null;
      final body = jsonDecode(res.body);
      if (body is! Map || body['result'] != 'success') return null;
      final rates = body['rates'];
      if (rates is! Map) return null;
      final bdt = rates['BDT'];
      if (bdt is num && bdt > 0) return bdt.toDouble();
      return null;
    } catch (_) {
      // Network error, timeout, or malformed JSON → treat as "no fresh rate".
      return null;
    }
  }
}
