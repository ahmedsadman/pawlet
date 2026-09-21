import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'app_services.dart';

const String _processTask = 'meowni.process';
const String _periodicName = 'meowni.process.periodic';

/// WorkManager entry point. Best-effort catch-up processing when the app is
/// killed (e.g. a backlog queued while offline). Must be top-level.
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

/// Initializes WorkManager and schedules the periodic processing pass.
class BackgroundWorker {
  const BackgroundWorker._();

  static Future<void> initialize() async {
    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      _periodicName,
      _processTask,
      frequency: const Duration(minutes: 15), // Android minimum
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }
}
