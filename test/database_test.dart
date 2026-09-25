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

    test('onUpgrade v2->v3 adds columns, app_meta, and indexes', () async {
      // Build a v2 sms_records table by hand, then run the real migration.
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('''
        CREATE TABLE sms_records (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sender TEXT NOT NULL,
          contact_name TEXT,
          content TEXT NOT NULL,
          timestamp INTEGER NOT NULL,
          status TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          updated_at INTEGER NOT NULL DEFAULT 0,
          next_attempt_at INTEGER,
          category TEXT,
          processed_at INTEGER
        )
      ''');
      // A pre-v3 row must survive the additive migration untouched.
      await db.insert('sms_records', {
        'sender': 'CHK',
        'content': 'x',
        'timestamp': 1,
        'status': 'success',
        'updated_at': 1,
      });

      await AppDatabase.onUpgrade(db, 2, 3);

      final cols = await _columnNames(db, 'sms_records');
      expect(cols, containsAll(['ignore_reason', 'failure_reason']));
      expect(await _tableNames(db), contains('app_meta'));
      final indexes = await _indexNames(db, 'sms_records');
      expect(
        indexes,
        containsAll(['idx_sms_status_updated', 'idx_sms_status_next']),
      );
      // Existing row preserved, new columns default to null.
      final row = (await db.query('sms_records')).single;
      expect(row['sender'], 'CHK');
      expect(row['ignore_reason'], isNull);
      expect(row['failure_reason'], isNull);
      await db.close();
    });
  });

  test(
    'onUpgrade v1->v2 migrates indexes, clears credit matchers, renames',
    () async {
      // Build the v1 banks table + its single unique index by hand, then run the
      // real migration and assert its effects (in-memory, no reopen needed).
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute('''
      CREATE TABLE banks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        account_type TEXT NOT NULL DEFAULT 'deposit',
        card_digits TEXT,
        last_balance TEXT,
        last_balance_at INTEGER,
        created_at INTEGER NOT NULL,
        matchers TEXT
      )
    ''');
      await db.execute('CREATE UNIQUE INDEX idx_banks_name ON banks (name)');
      // v1 enforced unique names, so each stored bank has a distinct name (this is
      // exactly the limitation v2 lifts). One credit card carries an old catalog
      // name + matchers, so the migration must both rename it and clear matchers.
      await insertBank(
        db,
        name: 'Eastern Bank Limited',
        accountType: 'deposit',
        matchers: const ['ebl'],
      );
      await insertBank(db, name: 'Mutual Trust Bank', matchers: const ['mtb']);
      await insertBank(
        db,
        name: 'Standard Chartered Bank (SCB)',
        accountType: 'credit',
        cardDigits: '4238|3241',
        matchers: const ['scb'],
      );

      await AppDatabase.onUpgrade(db, 1, 2);

      final names = await _indexNames(db);
      expect(names, containsAll(['idx_banks_deposit', 'idx_banks_credit']));
      expect(names, isNot(contains('idx_banks_name')));

      final rows = await db.query('banks', orderBy: 'id');
      expect(rows.map((r) => r['name']).toList(), [
        'EBL',
        'MTB',
        'StanChart (SCB)',
      ]);
      // Credit matchers cleared; deposit matchers untouched.
      final creditRow = rows.firstWhere((r) => r['account_type'] == 'credit');
      expect(creditRow['name'], 'StanChart (SCB)'); // renamed too
      expect(creditRow['matchers'], isNull);
      final depositEbl = rows.firstWhere((r) => r['name'] == 'EBL');
      expect(depositEbl['matchers'], 'ebl');

      // The whole point of v2: a deposit + a card can now share one name.
      await insertBank(
        db,
        name: 'EBL',
        accountType: 'credit',
        cardDigits: '5100|9999',
      );
      expect((await db.query('banks')).length, 4);
      await db.close();
    },
  );
}
