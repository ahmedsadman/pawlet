import 'package:another_telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../config/build_config.dart';
import '../data/banks_repository.dart';
import '../data/database.dart';
import '../data/secure_store.dart';
import '../data/settings_repository.dart';
import '../data/sms_repository.dart';
import '../models/sms_record.dart';
import '../utils/currency_format.dart';
import 'auth/attestation_service.dart';
import 'auth/play_integrity.dart';
import 'background_worker.dart';
import 'classification/classifier.dart';
import 'classification/tflite_local_classifier.dart';
import 'connectivity_service.dart';
import 'exchange_rate_service.dart';
import 'finance/finance_matcher.dart';
import 'finance/finance_writer.dart';
import 'llm/llm_mode.dart';
import 'llm/llm_provider.dart';
import 'llm/openrouter_provider.dart';
import 'llm/pawlet_proxy_provider.dart';
import 'llm/prompt_bundle.dart';
import 'notification_service.dart';
import 'processing_service.dart';

/// Wires the core services together. Constructed once for the UI isolate and
/// freshly (from scratch) inside background isolates, since those cannot share
/// the UI isolate's objects.
class AppServices {
  AppServices({
    required this.database,
    required this.smsRepository,
    required this.banksRepository,
    required this.settings,
    required this.connectivity,
    required this.notifications,
    required this.llmProvider,
    required this.attestation,
    required this.promptBundles,
    required this.localClassifier,
    required this.processingService,
    required this.exchangeRate,
  });

  final Database database;
  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final SettingsRepository settings;
  final ConnectivityService connectivity;
  final NotificationService notifications;

  /// Null in [LlmMode.none].
  final LlmProvider? llmProvider;

  /// Present only in [LlmMode.proxy]. The UI isolate warms it up on launch,
  /// resume and reconnect (see `refreshLlmNetworkState`).
  final AttestationService? attestation;

  /// The server's prompt bundle for [LlmMode.byok]. Built in every mode
  /// because it is free until refreshed, and only the UI refreshes it.
  final PromptBundleStore promptBundles;

  /// Owned on-device model; closed on dispose so its native interpreter is freed
  /// (each isolate builds its own bundle).
  final TfliteLocalClassifier localClassifier;
  final ProcessingService processingService;
  final ExchangeRateService exchangeRate;

  factory AppServices.from({
    required Database database,
    required SharedPreferences prefs,
    required String apiKey,
    required LlmMode mode,
  }) {
    final smsRepository = SmsRepository(database);
    final banksRepository = BanksRepository(database);
    final settings = SettingsRepository(prefs);
    final connectivity = ConnectivityService();
    final notifications = NotificationService(prefs: prefs);

    final promptBundles = PromptBundleStore(
      prefs: prefs,
      apiBase: BuildConfig.apiBase,
    );
    // A rejection is written straight to prefs from whichever isolate saw it.
    // The UI isolate moves its own mode later, outside any processing pass
    // (refreshLlmNetworkState), because flipping the mode rebuilds this
    // object.
    final attestation = mode == LlmMode.proxy
        ? AttestationService(
            apiBase: BuildConfig.apiBase,
            store: SecureStore(),
            integrity: PlayIntegrity(),
            onIneligible: () => settings.setAttestationIneligible(true),
          )
        : null;
    final LlmProvider? llmProvider = switch (mode) {
      LlmMode.proxy => PawletProxyProvider(
        apiBase: BuildConfig.apiBase,
        attestation: attestation!,
      ),
      LlmMode.byok => OpenRouterProvider(
        apiKey: apiKey,
        bundle: promptBundles.current,
      ),
      LlmMode.none => null,
    };

    final matcher = FinanceMatcher(database);
    final localClassifier = TfliteLocalClassifier();
    final exchangeRate = ExchangeRateService(prefs);
    final processingService = ProcessingService(
      smsRepository: smsRepository,
      banksRepository: banksRepository,
      classifier: Classifier(llmProvider, local: localClassifier),
      financeWriter: FinanceWriter(database),
      isOnline: connectivity.isOnline,
      currency: () => kBaseCurrency,
      // Offline, a fetch can only burn the 15s timeout on a request that cannot
      // succeed, on a path an incoming SMS drives synchronously — serve
      // whatever was cached instead.
      usdBdtRate: () async => await connectivity.isOnline()
          ? exchangeRate.usdToBdt()
          : exchangeRate.cachedUsdToBdt(),
      afterPass: matcher.runPending,
      onCounts: (failed) async {
        await notifications.reconcileFailures(failed);
      },
      reschedule: (delay) => delay == null
          ? BackgroundWorker.cancelCatchUp()
          : BackgroundWorker.scheduleCatchUp(delay),
    );
    return AppServices(
      database: database,
      smsRepository: smsRepository,
      banksRepository: banksRepository,
      settings: settings,
      connectivity: connectivity,
      notifications: notifications,
      llmProvider: llmProvider,
      attestation: attestation,
      promptBundles: promptBundles,
      localClassifier: localClassifier,
      processingService: processingService,
      exchangeRate: exchangeRate,
    );
  }

  /// Builds a fully standalone bundle (opens its own DB + prefs). Use from
  /// background isolates, which must init notifications themselves.
  static Future<AppServices> bootstrap() async {
    final database = await AppDatabase.open();
    final prefs = await SharedPreferences.getInstance();
    final apiKey = await SecureStore().readApiKey();
    final settings = SettingsRepository(prefs);
    // Reads the cached install source rather than the channel: MainActivity
    // does not exist in this isolate, so the channel would always answer "not
    // from Play" and resolve a different mode from the UI isolate.
    final mode = resolveLlmMode(
      fromPlay: settings.installedFromPlay,
      proxyConfigured: BuildConfig.proxyConfigured,
      hasKey: apiKey.isNotEmpty,
      attestationIneligible: settings.attestationIneligible,
    );
    final services = AppServices.from(
      database: database,
      prefs: prefs,
      apiKey: apiKey,
      mode: mode,
    );
    await services.notifications.init();
    return services;
  }

  /// UI-isolate dispose: closes the owned LLM http client and the on-device
  /// model's native interpreter. The database is app-wide (owned by the provider
  /// scope) and must NOT be closed here.
  void dispose() {
    _closeNetwork();
    localClassifier.close();
    exchangeRate.close();
  }

  /// Background-isolate dispose: closes the isolate-local LLM http client and the
  /// on-device model's native interpreter.
  ///
  /// The database is deliberately NOT closed. sqflite's default
  /// `singleInstance: true` shares a single native connection across every
  /// isolate in the process, so a background isolate (WorkManager catch-up,
  /// background SMS handler) closing it would close the live UI isolate's
  /// database too — every later query then throws
  /// `DatabaseException(database_closed)` and the UI hangs on a loading skeleton
  /// until the app is restarted. The shared connection is released when the
  /// process dies.
  Future<void> disposeStandalone() async {
    _closeNetwork();
    localClassifier.close();
    exchangeRate.close();
  }

  void _closeNetwork() {
    switch (llmProvider) {
      case final OpenRouterProvider p:
        p.close();
      case final PawletProxyProvider p:
        p.close();
      default:
        break;
    }
    attestation?.close();
    promptBundles.close();
  }

  /// Manual per-message retry: returns one failed message to the queue for a
  /// single re-process attempt, then runs the queue.
  Future<void> retryMessage(int id) async {
    await smsRepository.requeueOne(
      id,
      DateTime.now().millisecondsSinceEpoch,
      attempts: ProcessingService.maxAttempts - 1,
    );
    await processingService.process();
  }

  /// Persists an incoming SMS (deduped) and runs the processing queue.
  Future<void> handleIncomingSms(SmsMessage message) => handleIncomingRaw(
    sender: message.address ?? '',
    content: message.body ?? '',
    timestamp: message.date,
  );

  /// Raw-string entry point shared by the telephony listener and the debug
  /// injector. Persists (deduped) and runs the processing queue.
  Future<void> handleIncomingRaw({
    required String sender,
    required String content,
    int? timestamp,
  }) async {
    final trimmedSender = sender.trim();
    // Normalize newlines (CRLF/CR -> LF) and strip edge whitespace so dedup is
    // exact and the stored/displayed text is clean. Transport (JSON/DB) already
    // handles these chars safely; this is about content consistency.
    final normalizedContent = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .trim();
    if (trimmedSender.isEmpty || normalizedContent.isEmpty) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await smsRepository.insertIfNew(
      SmsRecord(
        sender: trimmedSender,
        content: normalizedContent,
        timestamp: timestamp ?? now,
        updatedAt: now,
      ),
    );

    // Processing now owns cleanup: process() calls a throttled pruneIfDue, so
    // there is no separate post-ingest prune here.
    await processingService.process();
  }
}
