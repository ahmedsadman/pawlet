import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

Future<Set<String>> _indexNames(Database db, [String table = 'banks']) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name=?",
    [table],
  );
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Set<String>> _columnNames(Database db, String table) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows.map((r) => r['name'] as String).toSet();
}

Future<Set<String>> _tableNames(Database db) async {
  final rows = await db.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table'",
  );
  return rows.map((r) => r['name'] as String).toSet();
}

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

  group('banks partial unique indexes (v2)', () {
    test(
      'fresh schema carries the two partial indexes, not idx_banks_name',
      () async {
        final db = await openTestDb();
        final names = await _indexNames(db);
        expect(names, containsAll(['idx_banks_deposit', 'idx_banks_credit']));
        expect(names, isNot(contains('idx_banks_name')));
        await db.close();
      },
    );

    test(
      'one deposit per bank name, but many cards under the same name',
      () async {
        final db = await openTestDb();
        await insertBank(db, name: 'EBL', accountType: 'deposit');
        // A deposit + two credit cards (distinct digits) all coexist under 'EBL'.
        await insertBank(
          db,
          name: 'EBL',
          accountType: 'credit',
          cardDigits: '4238|3241',
        );
        await insertBank(
          db,
          name: 'EBL',
          accountType: 'credit',
          cardDigits: '5100|9999',
        );
        expect((await db.query('banks')).length, 3);

        // A second EBL deposit is rejected by idx_banks_deposit.
        await expectLater(
          insertBank(db, name: 'EBL', accountType: 'deposit'),
          throwsA(isA<Exception>()),
        );
        // A duplicate card (same name + digits) is rejected by idx_banks_credit.
        await expectLater(
          insertBank(
            db,
            name: 'EBL',
            accountType: 'credit',
            cardDigits: '4238|3241',
          ),
          throwsA(isA<Exception>()),
        );
        await db.close();
      },
    );
  });

  group('sms_records retention schema (v3)', () {
    test('fresh schema carries the reason columns', () async {
      final db = await openTestDb();
      final cols = await _columnNames(db, 'sms_records');
      expect(cols, containsAll(['ignore_reason', 'failure_reason']));
      await db.close();
    });

    test('fresh schema creates app_meta', () async {
      final db = await openTestDb();
      expect(await _tableNames(db), contains('app_meta'));
      // Its PK/value shape lets pruneIfDue upsert an integer timestamp.
      await db.insert('app_meta', {'key': 'last_prune_at', 'value': 42});
      final rows = await db.query(
        'app_meta',
        where: 'key = ?',
        whereArgs: ['last_prune_at'],
      );
      expect(rows.single['value'], 42);
      await db.close();
    });

    test('fresh schema carries the two operational indexes', () async {
      final db = await openTestDb();
      final names = await _indexNames(db, 'sms_records');
      expect(
        names,
        containsAll(['idx_sms_status_updated', 'idx_sms_status_next']),
      );
      await db.close();
    });
  });

  group('sms_records parse_source schema (v4)', () {
    test('fresh schema carries the parse_source column', () async {
      final db = await openTestDb();
      final cols = await _columnNames(db, 'sms_records');
      expect(cols, contains('parse_source'));
      await db.close();
    });
  });

  group('transactions manual-entry schema', () {
    test('fresh schema allows a null message_id', () async {
      final db = await openTestDb();
      final bank = await insertBank(db, name: 'City', accountType: 'deposit');
      final id = await db.insert('transactions', {
        'message_id': null,
        'bank_id': bank,
        'normalized_amount': '10.00',
        'normalized_currency': 'BDT',
        'type': 'expense',
        'date': 1,
        'created_at': 1,
      });
      expect(id, greaterThan(0));
      final row =
          (await db.query('transactions', where: 'id = ?', whereArgs: [id]))
              .single;
      expect(row['message_id'], isNull);
      await db.close();
    });
  });

  group('destructive onUpgrade (pre-release policy)', () {
    test('any version bump drops old tables and rebuilds the current schema', () async {
      // Simulate an old install: a legacy transactions table with a NOT NULL
      // message_id and a stray row. onUpgrade must wipe and rebuild.
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('''
        CREATE TABLE transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER NOT NULL,
          normalized_amount TEXT NOT NULL,
          normalized_currency TEXT NOT NULL,
          type TEXT NOT NULL,
          date INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.insert('transactions', {
        'message_id': 42,
        'normalized_amount': '99.00',
        'normalized_currency': 'BDT',
        'type': 'income',
        'date': 5,
        'created_at': 5,
      });

      await AppDatabase.onUpgrade(db, 1, 5);

      // Rebuilt from scratch: old row is gone, all current tables exist.
      final tables = await _tableNames(db);
      expect(
        tables,
        containsAll(['sms_records', 'banks', 'transactions', 'bills', 'app_meta']),
      );
      expect((await db.query('transactions')).isEmpty, isTrue);

      // The rebuilt schema allows a null message_id.
      final id = await db.insert('transactions', {
        'message_id': null,
        'normalized_amount': '1.00',
        'normalized_currency': 'BDT',
        'type': 'expense',
        'date': 6,
        'created_at': 6,
      });
      expect(id, greaterThan(0));
      await db.close();
    });
  });
}
