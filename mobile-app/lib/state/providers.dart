import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/banks_repository.dart';
import '../data/finance_repository.dart';
import '../data/secure_store.dart';
import '../data/settings_repository.dart';
import '../data/sms_repository.dart';
import '../services/app_services.dart';
import '../services/backup_service.dart';
import '../services/processing_service.dart';
import '../services/sms_listener.dart';
import '../utils/currency_format.dart';

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
    currency: () => kBaseCurrency,
  ),
);

final secureStoreProvider = Provider<SecureStore>((ref) => SecureStore());

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    db: ref.watch(databaseProvider),
    settings: ref.watch(settingsRepositoryProvider),
  ),
);

/// The API key read from encrypted storage at startup, injected in `main()`.
final bootstrapApiKeyProvider = Provider<String>(
  (ref) =>
      throw UnimplementedError('bootstrapApiKeyProvider must be overridden'),
);

/// The current OpenRouter API key, seeded from encrypted storage at startup.
/// The pipeline reads it via [appServicesProvider]; there is no in-app writer
/// (the key is provisioned out-of-band via `--dart-define`, see [SecureStore]).
class ApiKey extends Notifier<String> {
  @override
  String build() => ref.read(bootstrapApiKeyProvider);
}

final apiKeyProvider = NotifierProvider<ApiKey, String>(ApiKey.new);

/// Bundles the SMS capture + processing pipeline for the UI isolate. Rebuilds
/// when the API key changes so the change takes effect without a restart.
final appServicesProvider = Provider<AppServices>((ref) {
  final services = AppServices.from(
    database: ref.watch(databaseProvider),
    prefs: ref.watch(sharedPreferencesProvider),
    apiKey: ref.watch(apiKeyProvider),
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

/// Bottom-navigation tab indices (Finance, Messages, Settings).
const int kMessagesTabIndex = 1;
const int kSettingsTabIndex = 2;

/// The selected bottom-nav tab, held in a provider so any page can switch tabs.
class SelectedTab extends Notifier<int> {
  @override
  int build() => 0;

  void select(int index) => state = index;
}

final selectedTabProvider = NotifierProvider<SelectedTab, int>(SelectedTab.new);

/// A monotonically increasing counter bumped whenever local data changes
/// (a processing pass committed writes, or the app resumed). Read-once finance
/// and history providers watch it, so a bump makes them re-read the DB — a
/// push-based alternative to polling. Lives in the UI isolate; background
/// isolates cannot (and need not) touch it.
class DataRevision extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final dataRevisionProvider = NotifierProvider<DataRevision, int>(
  DataRevision.new,
);

/// Foreground bridge for cross-isolate data changes. A processing pass in ANY
/// isolate (main, WorkManager catch-up, background-SMS) bumps a cheap DB token
/// ([SmsRepository.dataRevision]); this polls that token on a timer and, when it
/// moves, bumps [dataRevisionProvider] so History/Finance re-read. It's how the
/// UI hears about writes made by background isolates it can't be signalled from.
///
/// The timer only does work while the app is foreground: when backgrounded the
/// main isolate is frozen, so it doesn't fire (no idle battery cost). The token
/// read is a single primary-key lookup on `app_meta` — sub-millisecond — and the
/// expensive History/Finance reads run only on an actual change.
class DataRevisionSync {
  DataRevisionSync(
    this._readToken,
    this._bump, {
    this._interval = const Duration(seconds: 2),
  }) {
    _start();
  }

  final Future<int> Function() _readToken;
  final void Function() _bump;
  final Duration _interval;

  Timer? _timer;
  int _last = -1; // -1 => not yet observed; first read always refreshes once
  bool _busy = false;

  /// Whether the poll timer is currently running.
  bool get isPolling => _timer != null;

  void _start() => _timer ??= Timer.periodic(_interval, (_) => syncOnce());

  /// Stops polling — call when the app is backgrounded. We don't rely on the OS
  /// freezing the isolate to halt the timer; we stop it explicitly so there's no
  /// wake while the user is away.
  void pause() {
    _timer?.cancel();
    _timer = null;
  }

  /// Resumes polling — call when the app returns to the foreground.
  void resume() => _start();

  /// Reads the token; bumps the revision on the first observation (to catch a
  /// write that landed before polling started) and on every subsequent change.
  /// Re-entrancy-guarded so a slow read can't overlap the next tick.
  Future<void> syncOnce() async {
    if (_busy) return;
    _busy = true;
    try {
      final token = await _readToken();
      if (token != _last) {
        _last = token;
        _bump();
      }
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Owns the [DataRevisionSync] for the app's lifetime (kept alive by RootShell).
final dataRevisionSyncProvider = Provider<DataRevisionSync>((ref) {
  final repo = ref.watch(smsRepositoryProvider);
  final sync = DataRevisionSync(
    repo.dataRevision,
    () => ref.read(dataRevisionProvider.notifier).bump(),
  );
  ref.onDispose(sync.dispose);
  return sync;
});

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
