import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/database.dart';
import 'data/secure_store.dart';
import 'services/background_worker.dart';
import 'services/notification_service.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final database = await AppDatabase.open();
  final apiKey = await SecureStore().resolveApiKey();
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
