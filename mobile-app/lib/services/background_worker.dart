import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'app_services.dart';

const String _processTask = 'pawlet.process';
const String _catchUpName = 'pawlet.process.catchup';

/// WorkManager entry point. Best-effort catch-up when the app is killed (a
/// backlog queued while offline, or a message in retry backoff). Must be
/// top-level. The pass itself reschedules the next catch-up (or cancels it when
/// the queue is empty) via AppServices' reschedule hook.
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    AppServices? services;
    try {
      services = await AppServices.bootstrap();
      await services.processingService.process();
      return true;
    } catch (_) {
      return false; // let WorkManager reschedule
    } finally {
      await services?.disposeStandalone();
    }
  });
}

/// Adaptive background scheduling: instead of an always-on periodic task, a
/// single one-off catch-up is (re)scheduled only when there is pending work, so
/// an idle app never wakes in the background.
class BackgroundWorker {
  const BackgroundWorker._();

  static Future<void> initialize() =>
      Workmanager().initialize(callbackDispatcher);

  /// A catch-up is never scheduled sooner than this. Foreground work and incoming
  /// SMS are handled inline (and by the background-SMS isolate) already, so the
  /// WorkManager catch-up only backstops retry backoff and stale reclaim — none
  /// of which needs sub-second latency. This floor is defense-in-depth: it caps
  /// how fast a self-rescheduling catch-up can re-run, so a future scheduling bug
  /// can't turn it into a back-to-back WorkManager livelock.
  static const Duration _minCatchUp = Duration(seconds: 5);

  /// Schedules a catch-up pass after [delay] (floored to [_minCatchUp]), gated on
  /// connectivity so it fires when the network is available.
  ///
  /// Uses [ExistingWorkPolicy.keep] — NOT replace — so a catch-up already running
  /// (mid-LLM-call, holding the single in-flight slot) is never cancelled. Replace
  /// would stop that worker before it released its claimed row, orphaning it as
  /// `sending` until stale reclaim; a burst of reschedules then thrashed workers
  /// on/off. Keep lets the running pass finish and reschedule the next wake itself.
  static Future<void> scheduleCatchUp(Duration delay) =>
      Workmanager().registerOneOffTask(
        _catchUpName,
        _processTask,
        initialDelay: delay < _minCatchUp ? _minCatchUp : delay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.keep,
      );

  /// Cancels the pending catch-up (nothing left to process).
  static Future<void> cancelCatchUp() =>
      Workmanager().cancelByUniqueName(_catchUpName);
}
