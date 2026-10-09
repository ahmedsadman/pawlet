import 'package:flutter_test/flutter_test.dart';
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

    test('none has no provider at all', () async {
      final s = await build(LlmMode.none);
      expect(s.llmProvider, isNull);
      expect(s.attestation, isNull);
    });
  });

  group('model stats are sent only in proxy mode', () {
    for (final (mode, sends) in const [
      (LlmMode.proxy, true),
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
    }
  });
}
