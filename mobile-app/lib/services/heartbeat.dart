// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/build_config.dart';
import '../data/database.dart';
import '../data/heartbeat_repository.dart';
import 'app_services.dart';
import 'app_version.dart';
import 'background_worker.dart';
import 'heartbeat_reporter.dart';
import 'llm/llm_mode.dart';

/// Records that the app ran today, and whether it was opened, then lets the
/// reporter upload. Built in every mode but no-LLM (see `AppServices`).
///
/// Marks happen on launch and resume (opened), at the end of every
/// processing pass in any isolate, and from the daily WorkManager task
/// (alive). Never throws: analytics must not affect the app.
class Heartbeat {
  Heartbeat({
    required HeartbeatRepository repository,
    required HeartbeatReporter reporter,
    Future<int?> Function() appVersionCode = readAppVersionCode,
    int Function()? clock,
  }) : _repository = repository,
       _reporter = reporter,
       _appVersionCode = appVersionCode,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final HeartbeatRepository _repository;
  final HeartbeatReporter _reporter;
  final Future<int?> Function() _appVersionCode;
  final int Function() _clock;

  /// The app came to the foreground.
  Future<void> markOpened() => _mark(opened: true);

  /// The app's code ran, in any isolate.
  Future<void> markAlive() => _mark(opened: false);

  Future<void> _mark({required bool opened}) async {
    try {
      final version = await _appVersionCode();
      // Filing a day under a wrong version would be worse than missing it.
      if (version == null) return;
      await _repository.mark(
        opened: opened,
        nowMs: _clock(),
        appVersionCode: version,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('heartbeat: mark failed: $e');
      return;
    }
    await _reporter.maybeFlush();
  }

  /// Releases the reporter's HTTP client.
  void close() => _reporter.close();
}

/// Keeps the daily heartbeat task and the local log in step with [mode]:
/// scheduled in every mode but no-LLM; otherwise (no-LLM, or a build with no
/// server) cancelled and the unsent log deleted, so nothing leaves the phone.
/// Run by the UI isolate whenever the mode resolves. Never throws.
///
/// [apiBaseConfigured] defaults to [BuildConfig.apiBaseConfigured]; tests
/// pass it explicitly.
Future<void> syncHeartbeatMode({
  required LlmMode mode,
  required HeartbeatRepository repository,
  bool? apiBaseConfigured,
  Future<void> Function() schedule = BackgroundWorker.scheduleHeartbeat,
  Future<void> Function() cancel = BackgroundWorker.cancelHeartbeat,
}) async {
  final configured = apiBaseConfigured ?? BuildConfig.apiBaseConfigured;
  try {
    if (mode != LlmMode.none && configured) {
      await schedule();
    } else {
      // Delete the log first (privacy-relevant), then cancel. Each in its own
      // try so one failing doesn't skip the other.
      try {
        await repository.deleteAll();
      } catch (e) {
        if (kDebugMode) debugPrint('heartbeat: delete failed: $e');
      }
      try {
        await cancel();
      } catch (e) {
        if (kDebugMode) debugPrint('heartbeat: cancel failed: $e');
      }
    }
  } catch (e) {
    if (kDebugMode) debugPrint('heartbeat: mode sync failed: $e');
  }
}

/// The daily WorkManager heartbeat: marks today alive and uploads, without a
/// processing pass. Always reports success, so WorkManager never retries it;
/// a failed upload is retried by the reporter's own backoff on the next mark.
Future<bool> runHeartbeatTask() async {
  try {
    final database = await AppDatabase.open();
    final prefs = await SharedPreferences.getInstance();
    final heartbeat = await AppServices.standaloneHeartbeat(
      database: database,
      prefs: prefs,
    );
    if (heartbeat == null) return true;
    try {
      await heartbeat.markAlive();
    } finally {
      heartbeat.close();
    }
  } catch (e) {
    if (kDebugMode) debugPrint('heartbeat: task failed: $e');
  }
  return true;
}
