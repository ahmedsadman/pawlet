import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  // Cached here because MainActivity serves this channel and background
  // isolates have no MainActivity — they read the cache instead.
  await SettingsRepository(
    prefs,
  ).setInstalledFromPlay(await InstallSource().isFromPlayStore());
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
