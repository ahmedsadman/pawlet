import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/secure_store.dart';
import 'data/settings_repository.dart';
import 'services/background_worker.dart';
import 'services/install_source.dart';
import 'services/notification_service.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final database = await AppDatabase.open();
  final apiKey = await SecureStore().readApiKey();
  final settings = SettingsRepository(prefs);
  // Cached here because MainActivity serves this channel and background
  // isolates have no MainActivity — they read the cache instead.
  await settings.setInstalledFromPlay(await InstallSource().isFromPlayStore());
  // Before runApp, so every provider and isolate sees the expired flag.
  // If version lookup fails, the flag stays until the next launch.
  try {
    await settings.expireAttestationIneligible(
      build: (await PackageInfo.fromPlatform()).buildNumber,
      now: DateTime.now(),
    );
  } catch (_) {
    // Plugin failure must not block app startup.
  }
  // Inits the shared plugin singleton; the provider's NotificationService wraps
  // the same native instance.
  await NotificationService().init();
  await BackgroundWorker.initialize();

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(database),
        bootstrapApiKeyProvider.overrideWithValue(apiKey),
      ],
      child: const PawletApp(),
    ),
  );
}
