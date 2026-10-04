import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/app_services.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
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
}
