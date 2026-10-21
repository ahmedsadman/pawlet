import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../config/build_config.dart';
import '../data/banks_repository.dart';
import '../data/database.dart';
import '../data/heartbeat_repository.dart';
import '../data/model_stats_repository.dart';
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
import 'heartbeat.dart';
import 'heartbeat_reporter.dart';
import 'llm/llm_mode.dart';
import 'llm/llm_provider.dart';
import 'llm/openrouter_provider.dart';
import 'llm/pawlet_proxy_provider.dart';
import 'llm/prompt_bundle.dart';
import 'model_stats_reporter.dart';
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
    required this.modelStatsReporter,
    required this.heartbeat,
  });

  final Database database;
  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final SettingsRepository settings;
  final ConnectivityService connectivity;
  final NotificationService notifications;

  /// Null in [LlmMode.optedOut] and [LlmMode.none].
  final LlmProvider? llmProvider;

  /// Present only on the proxy session ([LlmMode.proxy] and
  /// [LlmMode.optedOut]). The UI isolate warms it up on launch, resume and
  /// reconnect (see `refreshLlmNetworkState`).
  final AttestationService? attestation;

  /// The server's prompt bundle for [LlmMode.byok]. Built in every mode
  /// because it is free until refreshed, and only the UI refreshes it.
  final PromptBundleStore promptBundles;

  /// Owned on-device model; closed on dispose so its native interpreter is freed
  /// (each isolate builds its own bundle).
  final TfliteLocalClassifier localClassifier;
  final ProcessingService processingService;
  final ExchangeRateService exchangeRate;

  /// Sends the on-device model's daily counts to Pawlet's server. Present only
  /// on the proxy session ([LlmMode.proxy] and [LlmMode.optedOut]), the only
  /// modes that count: BYOK and no-LLM installs neither count nor send, which
  /// keeps BYOK usage and no-LLM installs' model results off Pawlet's server.
  /// Opting out stops message text going to an LLM, not the counts.
  final ModelStatsReporter? modelStatsReporter;

  /// Records days the app ran or was opened and uploads them, with the
  /// install's LLM group. Present in every mode (including no-LLM) whenever
  /// the build has a server; null otherwise.
  final Heartbeat? heartbeat;

  /// The mode a background isolate runs in, from fresh prefs and the
  /// keystore. Reads the cached install source rather than the channel:
  /// MainActivity does not exist in a background isolate, so the channel
  /// would always answer "not from Play" and resolve a different mode from
  /// the UI isolate.
  static Future<({LlmMode mode, String apiKey})> standaloneMode(
    SharedPreferences prefs,
  ) async {
    // The background-SMS isolate reuses its engine, so its cached prefs would
    // otherwise keep a stale mode/flag for the life of the process.
    await prefs.reload();
    final apiKey = await SecureStore().readApiKey();
    final settings = SettingsRepository(prefs);
    final mode = resolveLlmMode(
      fromPlay: settings.installedFromPlay,
      proxyConfigured: BuildConfig.proxyConfigured,
      hasKey: apiKey.isNotEmpty,
      attestationIneligible: settings.attestationIneligible,
      llmEnabled: settings.llmEnabled,
    );
    return (mode: mode, apiKey: apiKey);
  }

  /// A heartbeat for an install in a build with a server, whose marks carry the
  /// current LLM group read from fresh prefs: the mode can move in another
  /// isolate while this object lives on.
  static Heartbeat _heartbeat({
    required Database database,
    required SharedPreferences prefs,
  }) {
    final repository = HeartbeatRepository(database);
    return Heartbeat(
      repository: repository,
      reporter: HeartbeatReporter(
        apiBase: BuildConfig.apiBase,
        repository: repository,
        installId: SecureStore().installId,
      ),
      llmGroup: () => heartbeatGroup(prefs),
    );
  }

  /// The install's LLM group for a heartbeat mark, from fresh prefs and the
  /// keystore ([standaloneMode], or [resolve] in tests). If that fails, the
  /// group comes from the prefs as they are, resolved as if no key is saved,
  /// so the mark is kept: a BYOK install then reports `none` for the day.
  /// ([SecureStore.readApiKey] already treats an unreadable keystore as no
  /// key.)
  @visibleForTesting
  static Future<String> heartbeatGroup(
    SharedPreferences prefs, {
    Future<({LlmMode mode, String apiKey})> Function(SharedPreferences)
        resolve =
        standaloneMode,
  }) async {
    try {
      return (await resolve(prefs)).mode.heartbeatGroup;
    } catch (_) {
      final settings = SettingsRepository(prefs);
      return resolveLlmMode(
        fromPlay: settings.installedFromPlay,
        proxyConfigured: BuildConfig.proxyConfigured,
        hasKey: false,
        attestationIneligible: settings.attestationIneligible,
        llmEnabled: settings.llmEnabled,
      ).heartbeatGroup;
    }
  }

  /// For the daily WorkManager task: a heartbeat when this install may send
  /// one, else null.
  static Future<Heartbeat?> standaloneHeartbeat({
    required Database database,
    required SharedPreferences prefs,
  }) async {
    return BuildConfig.apiBaseConfigured
        ? _heartbeat(database: database, prefs: prefs)
        : null;
  }

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
    // The UI isolate moves its own mode later via refreshLlmNetworkState, and
    // only while its ProcessingService is idle, because flipping the mode
    // rebuilds (and disposes) this object.
    final attestation = mode.usesProxySession
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
      LlmMode.optedOut || LlmMode.none => null,
    };

    final modelStats = ModelStatsRepository(database);
    // Whether the install is still on the proxy session. Attestation can flag
    // it ineligible (possibly from another isolate) while this bundle lives
    // on, so the mode is re-resolved from fresh prefs on every call. The key
    // only picks between byok and none, and the LLM switch only between proxy
    // and optedOut, so neither can move this answer. Offered only to a
    // proxy-session bundle: a byok bundle keeps calling OpenRouter even if
    // fresh prefs would now resolve proxy, and that usage must never be
    // counted.
    Future<bool> stillOnProxySession() async {
      await prefs.reload();
      return resolveLlmMode(
        fromPlay: settings.installedFromPlay,
        proxyConfigured: BuildConfig.proxyConfigured,
        hasKey: false,
        attestationIneligible: settings.attestationIneligible,
        llmEnabled: true,
      ).usesProxySession;
    }

    // Gated on the attestation service, which exists only on the proxy
    // session: the counts travel on it and nowhere else.
    final modelStatsReporter = attestation == null
        ? null
        : ModelStatsReporter(
            apiBase: BuildConfig.apiBase,
            repository: modelStats,
            attestation: attestation,
            isProxy: stillOnProxySession,
          );

    final heartbeat = BuildConfig.apiBaseConfigured
        ? _heartbeat(database: database, prefs: prefs)
        : null;

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
      // Counted only on the proxy session, re-checked per verdict with the
      // same resolution the reporter uses before each send.
      modelStats: modelStats,
      isProxy: attestation == null ? null : stillOnProxySession,
      // The user can turn the LLM off while this bundle lives on: the UI
      // rebuilds its bundle, possibly under a running pass, and a background
      // isolate's bundle never hears of it. So a proxy bundle re-reads the
      // switch from fresh prefs before every LLM call.
      llmAllowed: mode == LlmMode.proxy
          ? () async {
              await prefs.reload();
              return settings.llmEnabled;
            }
          : null,
      // Every pass, in any isolate, means the app ran today.
      onPassEnd: () async {
        await modelStatsReporter?.maybeFlush();
        await heartbeat?.markAlive();
      },
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
      modelStatsReporter: modelStatsReporter,
      heartbeat: heartbeat,
    );
  }

  /// Builds a fully standalone bundle (opens its own DB + prefs). Use from
  /// background isolates, which must init notifications themselves.
  static Future<AppServices> bootstrap() async {
    final database = await AppDatabase.open();
    final prefs = await SharedPreferences.getInstance();
    final (:mode, :apiKey) = await standaloneMode(prefs);
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

  /// [dispose], once no processing pass is running on this bundle. The UI
  /// rebuilds its bundle whenever the mode moves (the LLM switch, a saved
  /// key), possibly mid-pass; closing at once would free the on-device
  /// model's interpreter under a running inference and cut off the pass's
  /// network calls. Meanwhile the pass re-checks the LLM switch before each
  /// LLM call, so a turned-off LLM is still never called.
  Future<void> disposeWhenIdle() async {
    await processingService.whenIdle();
    dispose();
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
    modelStatsReporter?.close();
    heartbeat?.close();
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
    final normalizedContent = normalizeSmsContent(content);
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
