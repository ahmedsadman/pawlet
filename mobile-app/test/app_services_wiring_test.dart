import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // Force ConnectivityService.isOnline() to report online so process() runs a
    // real pass (connectivity_plus 7.x invokes 'check' expecting a String list).
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => call.method == 'check' ? <String>['wifi'] : null,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      null,
    );
  });

  test('appServicesProvider bumps dataRevision after a processing pass', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final Database db = await openTestDb();
    // A bank so the schema is populated; sender below is intentionally unmatched
    // (gated out) — a terminal, offline-safe outcome that still makes the pass
    // non-empty so onChanged fires without needing a real LLM key.
    await db.insert('banks', {
      'name': 'Checking',
      'account_type': 'deposit',
      'created_at': 0,
      'matchers': 'chk',
    });

    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        bootstrapApiKeyProvider.overrideWithValue('test-key'),
      ],
    );
    addTearDown(container.dispose);
    // Keep the counter alive so its state survives across reads.
    final sub = container.listen(dataRevisionProvider, (_, _) {});
    addTearDown(sub.close);

    final sms = SmsRepository(db);
    await sms.insertIfNew(
      SmsRecord(
        sender: 'DARAZ',
        content: 'win a prize',
        timestamp: 1,
        updatedAt: 1,
      ),
    );

    expect(container.read(dataRevisionProvider), 0);
    await container.read(processingServiceProvider).process();
    expect(container.read(dataRevisionProvider), greaterThan(0));

    await db.close();
  });
}
