import 'package:another_telephony/telephony.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../data/banks_repository.dart';
import '../data/database.dart';
import '../data/secure_store.dart';
import '../data/settings_repository.dart';
import '../data/sms_repository.dart';
import '../models/sms_record.dart';
import 'background_worker.dart';
import 'classification/classifier.dart';
import 'classification/onnx_local_classifier.dart';
import 'connectivity_service.dart';
import 'contact_resolver.dart';
import 'finance/finance_matcher.dart';
import 'finance/finance_writer.dart';
import 'llm/openrouter_provider.dart';
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
    required this.contactResolver,
    required this.connectivity,
    required this.notifications,
    required this.llmProvider,
    required this.processingService,
  });

  final Database database;
  final SmsRepository smsRepository;
  final BanksRepository banksRepository;
  final SettingsRepository settings;
  final ContactResolver contactResolver;
  final ConnectivityService connectivity;
  final NotificationService notifications;
  final OpenRouterProvider llmProvider;
  final ProcessingService processingService;

  factory AppServices.from({
    required Database database,
    required SharedPreferences prefs,
    required String apiKey,
  }) {
    final smsRepository = SmsRepository(database);
    final banksRepository = BanksRepository(database);
    final settings = SettingsRepository(prefs);
    final connectivity = ConnectivityService();
    final notifications = NotificationService(prefs: prefs);
    final llmProvider = OpenRouterProvider(
      apiKey: apiKey,
      models: SettingsRepository.defaultLlmModels,
    );
    final matcher = FinanceMatcher(database);
    final processingService = ProcessingService(
      smsRepository: smsRepository,
      banksRepository: banksRepository,
      classifier: Classifier(llmProvider, local: OnnxLocalClassifier()),
      financeWriter: FinanceWriter(database),
      isOnline: connectivity.isOnline,
      currency: () => settings.currency,
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
      contactResolver: ContactResolver(),
      connectivity: connectivity,
      notifications: notifications,
      llmProvider: llmProvider,
      processingService: processingService,
    );
  }

  /// Builds a fully standalone bundle (opens its own DB + prefs). Use from
  /// background isolates, which must init notifications themselves.
  static Future<AppServices> bootstrap() async {
    final database = await AppDatabase.open();
    final prefs = await SharedPreferences.getInstance();
    final apiKey = await SecureStore().resolveApiKey();
    final services = AppServices.from(
      database: database,
      prefs: prefs,
      apiKey: apiKey,
    );
    await services.notifications.init();
    return services;
  }

  /// UI-isolate dispose: closes the owned LLM http client only. The database is
  /// app-wide (owned by the provider scope) and must NOT be closed here.
  void dispose() => llmProvider.close();

  /// Background-isolate dispose: closes only the isolate-local LLM http client.
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
    llmProvider.close();
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

    final contactName = settings.resolveContacts
        ? await contactResolver.nameFor(trimmedSender)
        : null;

    final now = DateTime.now().millisecondsSinceEpoch;
    await smsRepository.insertIfNew(
      SmsRecord(
        sender: trimmedSender,
        contactName: contactName,
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
