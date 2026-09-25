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

  /// Schedules (replacing any pending one) a catch-up pass after [delay], gated
  /// on connectivity so it fires when the network is available.
  static Future<void> scheduleCatchUp(Duration delay) =>
      Workmanager().registerOneOffTask(
        _catchUpName,
        _processTask,
        initialDelay: delay,
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );

  /// Cancels the pending catch-up (nothing left to process).
  static Future<void> cancelCatchUp() =>
      Workmanager().cancelByUniqueName(_catchUpName);
}
