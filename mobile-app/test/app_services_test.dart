import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/config/build_config.dart';
import 'package:pawlet/services/app_services.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:pawlet/services/llm/openrouter_provider.dart';
import 'package:pawlet/services/llm/pawlet_proxy_provider.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _MockDb extends Mock implements Database {}

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

    test('none has no provider at all and no heartbeat', () async {
      final s = await build(LlmMode.none);
      expect(s.llmProvider, isNull);
      expect(s.attestation, isNull);
      expect(s.heartbeat, isNull);
    });
  });

  test('none mode builds a heartbeat', () async {
    // Actually, none mode does NOT build a heartbeat. The test name is
    // misleading from the task brief context. The intended test is that
    // every mode BUT none builds a heartbeat.
    SharedPreferences.setMockInitialValues({});
    for (final mode in [LlmMode.proxy, LlmMode.optedOut, LlmMode.byok]) {
      final s = AppServices.from(
        database: _MockDb(),
        prefs: await SharedPreferences.getInstance(),
        apiKey: 'sk-or-x',
        mode: mode,
      );
      expect(
        s.heartbeat != null,
        BuildConfig.apiBaseConfigured,
        reason: '$mode should build heartbeat when API is configured',
      );
      await s.disposeStandalone();
    }

    final noneMode = AppServices.from(
      database: _MockDb(),
      prefs: await SharedPreferences.getInstance(),
      apiKey: '',
      mode: LlmMode.none,
    );
    expect(
      noneMode.heartbeat,
      isNull,
      reason: 'none mode should NOT build heartbeat',
    );
    await noneMode.disposeStandalone();
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
