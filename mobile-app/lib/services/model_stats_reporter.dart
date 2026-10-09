// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;

import '../data/model_stats_repository.dart';
import 'auth/attestation_service.dart';

/// Sends the on-device model's daily verdict counts to Pawlet's server
/// (`POST /v1/model-stats`), so the admin dashboard can show how many messages
/// the model settles without the LLM.
///
/// Built only in proxy mode (see AppServices), the only mode that counts:
/// BYOK and no-LLM installs neither count nor send. Triggered at the end of
/// every processing pass and on app resume; [maybeFlush] decides whether
/// anything goes out.
///
/// Never blocks or fails message processing: every error is swallowed and the
/// rows simply stay unreported until the next trigger.
class ModelStatsReporter {
  ModelStatsReporter({
    required this.apiBase,
    required ModelStatsRepository repository,
    required AttestationService attestation,
    required Future<bool> Function() isProxy,
    http.Client? client,
    int Function()? clock,
  }) : _repository = repository,
       _attestation = attestation,
       _isProxy = isProxy,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String apiBase;
  final ModelStatsRepository _repository;
  final AttestationService _attestation;

  /// Whether the install is in proxy mode right now. This object outlives a
  /// mode change made in another isolate (attestation flagging the install
  /// ineligible), so the mode is re-read before anything is sent.
  final Future<bool> Function() _isProxy;
  final http.Client _client;
  final bool _ownsClient;
  final int Function() _clock;

  /// Least time between two acknowledged flushes, across all isolates.
  static const Duration minGap = Duration(hours: 6);

  /// Most rows one request carries; the server's limit.
  static const int maxDays = 31;

  static const Duration requestTimeout = Duration(seconds: 20);

  Future<void>? _inflight;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Flushes unless a flush is already running in this isolate (the caller
  /// then shares it), the last acknowledged flush was under [minGap] ago, or
  /// nothing changed. Never throws.
  Future<void> maybeFlush() =>
      _inflight ??= _flushSafely().whenComplete(() => _inflight = null);

  Future<void> _flushSafely() async {
    try {
      await _flush();
    } catch (e) {
      if (kDebugMode) debugPrint('model stats: flush failed: $e');
    }
  }

  Future<void> _flush() async {
    final startedAt = _clock();
    final last = await _repository.flushedAt();
    // A stamp in the future (the clock moved back) does not hold flushes off.
    if (last != null &&
        last <= startedAt &&
        startedAt - last < minGap.inMilliseconds) {
      return;
    }

    final minDay = oldestKeptDay(startedAt);
    await _repository.pruneBefore(minDay);
    final rows = await _repository.unreported(minDay: minDay, limit: maxDays);
    if (rows.isEmpty) return;
    final body = jsonEncode({
      'days': [for (final r in rows) r.toJson()],
    });

    // Only proxy installs send: no token, no request, no throttle stamp.
    if (!await _stillProxy()) return;

    var token = await _token();
    if (token == null) return;
    var resp = await _post(body, token);
    if (resp == null) return;
    if (resp.statusCode == 401) {
      token = await _token(forceRefresh: true);
      if (token == null) return;
      resp = await _post(body, token);
      if (resp == null) return;
    }

    final code = resp.statusCode;
    if (code >= 200 && code < 300) {
      await _repository.markReported(rows, startedAt);
      await _repository.setFlushedAt(startedAt);
    } else if (code == 400) {
      // A rejected payload is a bug; resending it would loop forever.
      if (kDebugMode) debugPrint('model stats: rejected (400): ${resp.body}');
      await _repository.markReported(rows, startedAt);
    }
    // 401 after a refresh, 403 (the session path handles bans), 404, 408,
    // 429, 5xx: nothing is stamped and the next trigger tries again.
  }

  /// [_isProxy], with a failed check counted as "not proxy".
  Future<bool> _stillProxy() async {
    try {
      return await _isProxy();
    } catch (_) {
      return false;
    }
  }

  /// The proxy session token, or null when none can be had right now (a
  /// background isolate cannot mint, a cooldown is held, the install is
  /// ineligible).
  Future<String?> _token({bool forceRefresh = false}) async {
    try {
      return await _attestation.token(forceRefresh: forceRefresh);
    } catch (_) {
      return null;
    }
  }

  /// The server's answer, or null on a network error or timeout.
  Future<http.Response?> _post(String body, String token) async {
    try {
      return await _client
          .post(
            Uri.parse('$apiBase/v1/model-stats'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: body,
          )
          .timeout(requestTimeout);
    } catch (_) {
      return null;
    }
  }
}
