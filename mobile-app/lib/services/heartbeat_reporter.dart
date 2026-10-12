// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:http/http.dart' as http;

import '../data/heartbeat_repository.dart';
import '../data/model_stats_repository.dart' show oldestKeptDay, utcDay;
import 'upload_backoff.dart';

/// Sends the heartbeat log to Pawlet's server (`POST /v1/heartbeat`), so the
/// admin dashboard knows which days each install was opened or ran, and the
/// build it ran, without depending on proxy sessions.
///
/// Unauthenticated: the body carries the install ID, which the server hashes
/// before storing, exactly as `/v1/session` does. Sent only while the install
/// is in proxy or BYOK mode ([_isAllowed], re-read before every send).
///
/// Never blocks or fails its callers: every error is swallowed and rows stay
/// unreported. A failed upload puts the next attempt off (see
/// [kUploadBackoff]) across all isolates.
class HeartbeatReporter {
  HeartbeatReporter({
    required this.apiBase,
    required HeartbeatRepository repository,
    required Future<String> Function() installId,
    required Future<bool> Function() isAllowed,
    http.Client? client,
    int Function()? clock,
  }) : _repository = repository,
       _installId = installId,
       _isAllowed = isAllowed,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String apiBase;
  final HeartbeatRepository _repository;
  final Future<String> Function() _installId;
  final Future<bool> Function() _isAllowed;
  final http.Client _client;
  final bool _ownsClient;
  final int Function() _clock;

  /// Least time between two acknowledged flushes, across all isolates,
  /// unless a new build is running.
  static const Duration minGap = Duration(hours: 1);

  /// Most days one request carries; the server's limit.
  static const int maxDays = 31;

  static const Duration requestTimeout = Duration(seconds: 20);

  Future<void>? _inflight;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Flushes unless a flush is already running in this isolate (the caller
  /// then shares it), a failed upload is being backed off, nothing changed,
  /// or the last acknowledged flush was under [minGap] ago and the build is
  /// the one last reported. Never throws.
  Future<void> maybeFlush() =>
      _inflight ??= _flushSafely().whenComplete(() => _inflight = null);

  Future<void> _flushSafely() async {
    try {
      await _flush();
    } catch (e) {
      if (kDebugMode) debugPrint('heartbeat: flush failed: $e');
    }
  }

  Future<void> _flush() async {
    final startedAt = _clock();
    final schedule = _repository.schedule;
    // A retry time too far ahead (the clock moved back) holds nothing off.
    final retryAt = await schedule.retryAt();
    if (retryAt != null &&
        startedAt < retryAt &&
        retryAt - startedAt <= kUploadBackoffCap.inMilliseconds) {
      return;
    }

    final minDay = oldestKeptDay(startedAt);
    await _repository.pruneBefore(minDay);
    final rows = await _repository.unreported(
      minDay: minDay,
      maxDay: utcDay(startedAt + Duration.millisecondsPerDay),
      limit: maxDays,
    );
    if (rows.isEmpty) return;

    final newBuild =
        rows.last.appVersionCode != await _repository.reportedVersion();
    final last = await schedule.flushedAt();
    // A stamp in the future (the clock moved back) does not hold flushes off.
    if (!newBuild &&
        last != null &&
        last <= startedAt &&
        startedAt - last < minGap.inMilliseconds) {
      return;
    }

    if (!await _allowed()) return;
    final String id;
    try {
      id = await _installId();
    } catch (_) {
      // Keystore trouble is not the server's fault: keep the rows, no backoff.
      return;
    }

    final resp = await _post(
      jsonEncode({
        'installId': id,
        'days': [for (final r in rows) r.toJson()],
      }),
    );
    if (resp == null) return _failed();

    final code = resp.statusCode;
    if (code >= 200 && code < 300) {
      await _repository.markReported(rows, startedAt);
      await schedule.setFlushedAt(startedAt);
      await _repository.setReportedVersion(rows.last.appVersionCode);
      await schedule.clearBackoff();
    } else if (code == 400) {
      // A rejected payload is a bug; resending it would loop forever.
      if (kDebugMode) debugPrint('heartbeat: rejected (400): ${resp.body}');
      await _repository.markReported(rows, startedAt);
      await _repository.setReportedVersion(rows.last.appVersionCode);
      await schedule.clearBackoff();
    } else if (code == 429) {
      await _failed(
        fixed: kUploadBackoff.retryAfter(resp.headers['retry-after'], _clock()),
      );
    } else {
      await _failed();
    }
  }

  /// Counts a failed upload and puts the next attempt off by [fixed], or by
  /// the doubling backoff when null.
  Future<void> _failed({Duration? fixed}) {
    final now = _clock();
    return _repository.schedule.recordFailure(
      (failures) =>
          now + (fixed ?? kUploadBackoff.forFailures(failures)).inMilliseconds,
    );
  }

  /// [_isAllowed], with a failed check counted as "not allowed".
  Future<bool> _allowed() async {
    try {
      return await _isAllowed();
    } catch (_) {
      return false;
    }
  }

  /// The server's answer, or null on a network error or timeout.
  Future<http.Response?> _post(String body) async {
    try {
      return await _client
          .post(
            Uri.parse('$apiBase/v1/heartbeat'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(requestTimeout);
    } catch (_) {
      return null;
    }
  }
}
