import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('schema creates all tables', () async {
    final db = await openTestDb();
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table'",
    );
    final tables = rows.map((r) => r['name'] as String).toSet();
    expect(
      tables,
      containsAll(['sms_records', 'banks', 'transactions', 'bills']),
    );
    await db.close();
  });

  test('sms_records enforces the dedupe unique index', () async {
    final db = await openTestDb();
    await insertSms(db, sender: 'A', content: 'x', ts: 1);
    // Same (sender, timestamp, content) must be rejected.
    await expectLater(
      insertSms(db, sender: 'A', content: 'x', ts: 1),
      throwsA(isA<Exception>()),
    );
    await db.close();
  });
}
