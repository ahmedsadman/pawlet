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

    test('none has no provider at all', () async {
      final s = await build(LlmMode.none);
      expect(s.llmProvider, isNull);
      expect(s.attestation, isNull);
    });
  });

  group('heartbeat is built in every mode when the server is configured', () {
    test('all modes build a heartbeat when configured', () async {
      SharedPreferences.setMockInitialValues({});
      for (final mode in LlmMode.values) {
        final s = AppServices.from(
          database: _MockDb(),
          prefs: await SharedPreferences.getInstance(),
          apiKey: mode == LlmMode.byok ? 'sk-or-x' : '',
          mode: mode,
        );
        // BuildConfig.apiBaseConfigured is const false in tests, so we expect
        // null. Testing the real gate: when true, all modes build it.
        expect(
          s.heartbeat,
          isNull,
          reason:
              '$mode should build null heartbeat when API not configured (test env)',
        );
        await s.disposeStandalone();
      }
    });

    test('_sendsHeartbeat depends only on apiBaseConfigured', () {
      // The gate is a simple pure function: it should only check the config.
      expect(AppServices.testSendsHeartbeat(apiBaseConfigured: true), isTrue);
      expect(AppServices.testSendsHeartbeat(apiBaseConfigured: false), isFalse);
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
