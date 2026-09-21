import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/banks_repository.dart';
import '../data/finance_repository.dart';
import '../data/settings_repository.dart';
import '../data/sms_repository.dart';
import '../services/app_services.dart';
import '../services/processing_service.dart';
import '../services/sms_listener.dart';

/// Overridden in `main()` (and in tests) once async initialization completes.
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) =>
      throw UnimplementedError('sharedPreferencesProvider must be overridden'),
);
final databaseProvider = Provider<Database>(
  (ref) => throw UnimplementedError('databaseProvider must be overridden'),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(sharedPreferencesProvider)),
);

final banksRepositoryProvider = Provider<BanksRepository>(
  (ref) => BanksRepository(ref.watch(databaseProvider)),
);

final financeRepositoryProvider = Provider<FinanceRepository>(
  (ref) => FinanceRepository(
    ref.watch(databaseProvider),
    currency: () => ref.read(settingsRepositoryProvider).currency,
  ),
);

/// Bundles the SMS capture + processing pipeline for the UI isolate.
///
/// The LLM API key / model are read once here at build time. Phase 8 (Settings)
/// must `ref.invalidate(appServicesProvider)` after the user changes the key so
/// the foreground pipeline picks it up without an app restart.
final appServicesProvider = Provider<AppServices>((ref) {
  final services = AppServices.from(
    database: ref.watch(databaseProvider),
    prefs: ref.watch(sharedPreferencesProvider),
  );
  ref.onDispose(services.dispose);
  return services;
});

final smsRepositoryProvider = Provider<SmsRepository>(
  (ref) => ref.watch(appServicesProvider).smsRepository,
);

final processingServiceProvider = Provider<ProcessingService>(
  (ref) => ref.watch(appServicesProvider).processingService,
);

final smsListenerProvider = Provider<SmsListener>(
  (ref) => SmsListener(ref.watch(appServicesProvider)),
);

/// Index of the Settings tab in the bottom navigation (Finance, Messages,
/// Settings). Used by pages that deep-link to Settings.
const int kSettingsTabIndex = 2;

/// The selected bottom-nav tab, held in a provider so any page can switch tabs.
class SelectedTab extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final selectedTabProvider = NotifierProvider<SelectedTab, int>(SelectedTab.new);

/// Whether monetary values are masked across the Finance tab. Persisted locally
/// so the choice survives restarts.
class BalanceHidden extends Notifier<bool> {
  @override
  bool build() => ref.watch(settingsRepositoryProvider).hideBalance;

  Future<void> toggle() async {
    final value = !state;
    await ref.read(settingsRepositoryProvider).setHideBalance(value);
    state = value;
  }
}

final balanceHiddenProvider = NotifierProvider<BalanceHidden, bool>(
  BalanceHidden.new,
);
