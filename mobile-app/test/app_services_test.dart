import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/config/build_config.dart';
import 'package:pawlet/data/banks_repository.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/services/app_services.dart';
import 'package:pawlet/services/auth/attestation_service.dart';
import 'package:pawlet/services/classification/classifier.dart';
import 'package:pawlet/services/classification/tflite_local_classifier.dart';
import 'package:pawlet/services/connectivity_service.dart';
import 'package:pawlet/services/exchange_rate_service.dart';
import 'package:pawlet/services/finance/finance_writer.dart';
import 'package:pawlet/services/llm/prompt_bundle.dart';
import 'package:pawlet/services/notification_service.dart';
import 'package:pawlet/services/processing_service.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:pawlet/services/llm/openrouter_provider.dart';
import 'package:pawlet/services/llm/pawlet_proxy_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _MockDb extends Mock implements Database {}

class _MockSms extends Mock implements SmsRepository {}

class _MockLocal extends Mock implements TfliteLocalClassifier {}

class _MockAttestation extends Mock implements AttestationService {}

class _MockExchangeRate extends Mock implements ExchangeRateService {}

class _MockPromptBundles extends Mock implements PromptBundleStore {}

/// A bundle whose processing pass blocks inside its first step until
/// [releasePass] completes, with mocks standing in for everything [dispose]
/// closes.
({
  AppServices services,
  Completer<void> releasePass,
  _MockLocal local,
  _MockAttestation attestation,
})
_blockingBundle() {
  final db = _MockDb();
  final sms = _MockSms();
  final releasePass = Completer<void>();
  when(() => sms.reclaimStale(any())).thenAnswer((_) => releasePass.future);
  final local = _MockLocal();
  final attestation = _MockAttestation();
  final exchangeRate = _MockExchangeRate();
  final promptBundles = _MockPromptBundles();
  final processing = ProcessingService(
    smsRepository: sms,
    // Unstubbed, so the pass ends on its first call after the release; the
    // pass swallows that error.
    banksRepository: BanksRepository(db),
    classifier: Classifier(null, local: local),
    financeWriter: FinanceWriter(db),
    isOnline: () async => true,
    currency: () => 'BDT',
  );
  final services = AppServices(
    database: db,
    smsRepository: sms,
    banksRepository: BanksRepository(db),
    settings: _MockSettings(),
    connectivity: ConnectivityService(),
    notifications: _MockNotifications(),
    llmProvider: null,
    attestation: attestation,
    promptBundles: promptBundles,
    localClassifier: local,
    processingService: processing,
    exchangeRate: exchangeRate,
    modelStatsReporter: null,
    heartbeat: null,
  );
  return (
    services: services,
    releasePass: releasePass,
    local: local,
    attestation: attestation,
  );
}

class _MockSettings extends Mock implements SettingsRepository {}

class _MockNotifications extends Mock implements NotificationService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Regression: sqflite's default `singleInstance: true` shares one native
  // connection across every isolate in the process. A background isolate
  // (WorkManager catch-up, background SMS handler) that closes the database on
  // teardown therefore closes the live UI isolate's database too — every later
  // query throws DatabaseException(database_closed) and the UI is stuck loading
  // until the app is restarted. So the standalone teardown must NOT close it.
  test('disposeStandalone does not close the shared database', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = _MockDb();
    when(() => db.close()).thenAnswer((_) async {});
    final services = AppServices.from(
      database: db,
      prefs: prefs,
      apiKey: '',
      mode: LlmMode.none,
    );

    await services.disposeStandalone();

    verifyNever(() => db.close());
  });

  // Flipping the LLM switch or saving a key rebuilds the UI isolate's bundle,
  // possibly while a pass is still running on the old one. Freeing the
  // interpreter or the network mid-pass could crash native inference or cut
  // a call off, so the close waits for the pass.
  group('disposeWhenIdle', () {
    test('waits for a running pass before closing', () async {
      final b = _blockingBundle();
      final pass = b.services.processingService.process();
      await pumpEventQueue();
      expect(b.services.processingService.isRunning, isTrue);

      final disposed = b.services.disposeWhenIdle();
      await pumpEventQueue();
      verifyNever(() => b.local.close());
      verifyNever(() => b.attestation.close());

      b.releasePass.complete();
      await pass;
      await disposed;
      verify(() => b.local.close()).called(1);
      verify(() => b.attestation.close()).called(1);
    });

    test('closes at once when no pass is running', () async {
      final b = _blockingBundle();
      await b.services.disposeWhenIdle();
      verify(() => b.local.close()).called(1);
      verify(() => b.attestation.close()).called(1);
    });
  });

  group('the provider follows the mode', () {
    Future<AppServices> build(LlmMode mode) async {
      SharedPreferences.setMockInitialValues({});
      final services = AppServices.from(
        database: _MockDb(),
        prefs: await SharedPreferences.getInstance(),
        apiKey: 'sk-or-x',
        mode: mode,
      );
      addTearDown(services.disposeStandalone);
      return services;
    }

    test('proxy calls the server and can attest', () async {
      final s = await build(LlmMode.proxy);
      expect(s.llmProvider, isA<PawletProxyProvider>());
      expect(s.attestation, isNotNull);
    });

    test('byok calls OpenRouter and never attests', () async {
      final s = await build(LlmMode.byok);
      expect(s.llmProvider, isA<OpenRouterProvider>());
      expect(s.attestation, isNull);
    });

    test(
      'optedOut builds attestation, model stats and heartbeat but no LLM provider',
      () async {
        final s = await build(LlmMode.optedOut);
        expect(s.llmProvider, isNull);
        expect(s.attestation, isNotNull);
        expect(s.modelStatsReporter, isNotNull);
        expect(s.processingService.isProxy, isNotNull);
        // Same rule as proxy: present whenever the build has a server.
        expect(s.heartbeat != null, BuildConfig.apiBaseConfigured);
        // No provider to guard.
        expect(s.processingService.llmAllowed, isNull);
      },
    );

    test('proxy re-reads the LLM switch from fresh prefs', () async {
      final s = await build(LlmMode.proxy);
      final allowed = s.processingService.llmAllowed!;
      expect(await allowed(), isTrue);

      // Another isolate (or the UI notifier) turned the LLM off: the write
      // reaches the platform store but not this isolate's prefs cache.
      SharedPreferences.setMockInitialValues({'llm_enabled': false});
      expect(await allowed(), isFalse);
    });

    test('none has no provider at all', () async {
      final s = await build(LlmMode.none);
      expect(s.llmProvider, isNull);
      expect(s.attestation, isNull);
    });
  });

  group('heartbeat', () {
    // The same rule for every mode: present exactly when the build has a
    // server. Tests run without one, so this pins the "absent" half.
    test('every mode follows the build\'s server config alone', () async {
      SharedPreferences.setMockInitialValues({});
      for (final mode in LlmMode.values) {
        final s = AppServices.from(
          database: _MockDb(),
          prefs: await SharedPreferences.getInstance(),
          apiKey: mode == LlmMode.byok ? 'sk-or-x' : '',
          mode: mode,
        );
        expect(
          s.heartbeat != null,
          BuildConfig.apiBaseConfigured,
          reason: '$mode',
        );
        await s.disposeStandalone();
      }
    });

    test('the group resolves from fresh prefs', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(
        await AppServices.heartbeatGroup(prefs),
        (await AppServices.standaloneMode(prefs)).mode.heartbeatGroup,
      );
    });

    // A failed resolution would otherwise drop the day's mark altogether.
    test('a failed resolution falls back to prefs, as if no key', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final group = await AppServices.heartbeatGroup(
        prefs,
        resolve: (_) async => throw StateError('keystore locked'),
      );
      expect(
        group,
        resolveLlmMode(
          fromPlay: false,
          proxyConfigured: BuildConfig.proxyConfigured,
          hasKey: false,
          attestationIneligible: false,
          llmEnabled: true,
        ).heartbeatGroup,
      );
    });
  });

  group('model stats are sent only on the proxy session', () {
    for (final (mode, sends) in const [
      (LlmMode.proxy, true),
      (LlmMode.optedOut, true),
      (LlmMode.byok, false),
      (LlmMode.none, false),
    ]) {
      test('${mode.name} ${sends ? 'has' : 'has no'} reporter', () async {
        SharedPreferences.setMockInitialValues({});
        final s = AppServices.from(
          database: _MockDb(),
          prefs: await SharedPreferences.getInstance(),
          apiKey: 'sk-or-x',
          mode: mode,
        );
        addTearDown(s.disposeStandalone);

        expect(s.modelStatsReporter != null, sends);
      });

      test(
        '${mode.name} ${sends ? 'counts' : 'does not count'} verdicts',
        () async {
          SharedPreferences.setMockInitialValues({});
          final s = AppServices.from(
            database: _MockDb(),
            prefs: await SharedPreferences.getInstance(),
            apiKey: 'sk-or-x',
            mode: mode,
          );
          addTearDown(s.disposeStandalone);

          expect(s.processingService.isProxy != null, sends);
        },
      );
    }
  });
}
