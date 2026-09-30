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

/// Full column definitions, not just names, so a hand-written migration that
/// drifts from [AppDatabase.createSchema] on a type, a NOT NULL or a default is
/// caught instead of passing a names-only comparison.
Future<List<Map<String, Object?>>> _columnSpecs(
  Database db,
  String table,
) async {
  final rows = await db.rawQuery('PRAGMA table_info($table)');
  return rows
      .map(
        (r) => {
          'name': r['name'],
          'type': r['type'],
          'notnull': r['notnull'],
          'dflt_value': r['dflt_value'],
          'pk': r['pk'],
        },
      )
      .toList();
}

/// Index name -> its CREATE statement, so a same-named index rebuilt over
/// different columns is caught rather than passing a names-only comparison.
///
/// Whitespace is collapsed because the frozen v5 fixture writes its index DDL
/// on one line while createSchema uses multi-line blocks; SQL whitespace is
/// insignificant here, so normalizing it compares structure rather than layout.
///
/// Indexes SQLite creates for itself (a PRIMARY KEY or UNIQUE constraint in the
/// table body, e.g. `app_meta.key`) carry a null `sql`. They are still worth
/// comparing by name — losing one means the constraint went with it — so they
/// are kept under a marker rather than dropped.
Future<Map<String, String>> _indexDdl(Database db, String table) async {
  final rows = await db.rawQuery(
    "SELECT name, sql FROM sqlite_master WHERE type='index' AND tbl_name=?",
    [table],
  );
  return {
    for (final r in rows)
      r['name'] as String:
          (r['sql'] as String?)?.replaceAll(RegExp(r'\s+'), ' ').trim() ??
          '<implicit>',
  };
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

  test('a schema bump needs a migration branch and a parity test', () {
    // Deliberately brittle. onUpgrade falls through to a silent no-op for any
    // version pair it has no branch for, so a bump that forgets its branch
    // ships a database the app queries with the wrong schema and no failing
    // test. Update this only together with the branch and its parity test.
    expect(AppDatabase.version, 6);
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
      final row = (await db.query(
        'transactions',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['message_id'], isNull);
      await db.close();
    });
  });

  group('destructive onUpgrade (unmigrated version jumps)', () {
    test(
      'a pre-release version drops old tables and rebuilds the current schema',
      () async {
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

        await AppDatabase.onUpgrade(db, 1, 6);

        // Rebuilt from scratch: old row is gone, all current tables exist.
        final tables = await _tableNames(db);
        expect(
          tables,
          containsAll([
            'sms_records',
            'banks',
            'transactions',
            'bills',
            'app_meta',
          ]),
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
      },
    );
  });

  group('needs_llm migration (v5 -> v6)', () {
    // The complete v5 shape, frozen here because createSchema now describes
    // v6: an upgrade test needs the schema it is upgrading FROM. Every table
    // is reproduced, not just the one v6 alters — the parity check below is
    // only as wide as this fixture, and a future migration that forgets to
    // touch `banks`/`transactions`/`bills`/`app_meta` has to have something to
    // drift away from.
    Future<Database> openV5() async {
      final db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      // The only table whose v5 shape differs from v6: no needs_llm.
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
          processed_at INTEGER,
          ignore_reason TEXT,
          failure_reason TEXT,
          parse_source TEXT
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX idx_sms_unique '
        'ON sms_records (sender, timestamp, content)',
      );
      await db.execute(
        'CREATE INDEX idx_sms_status_updated ON sms_records (status, updated_at)',
      );
      await db.execute(
        'CREATE INDEX idx_sms_status_next ON sms_records (status, next_attempt_at)',
      );

      await db.execute('''
        CREATE TABLE app_meta (
          key TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        )
      ''');

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
      await db.execute(
        "CREATE UNIQUE INDEX idx_banks_deposit ON banks (name) "
        "WHERE account_type = 'deposit'",
      );
      await db.execute(
        "CREATE UNIQUE INDEX idx_banks_credit ON banks (name, card_digits) "
        "WHERE account_type = 'credit'",
      );

      await db.execute('''
        CREATE TABLE transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER,
          bank_id INTEGER,
          paired_with_id INTEGER,
          bill_id INTEGER,
          normalized_amount TEXT NOT NULL,
          normalized_currency TEXT NOT NULL,
          original_amount TEXT,
          original_currency TEXT,
          type TEXT NOT NULL,
          date INTEGER NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX idx_tx_message ON transactions (message_id)',
      );
      await db.execute('CREATE INDEX idx_tx_date ON transactions (date)');

      await db.execute('''
        CREATE TABLE bills (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          message_id INTEGER NOT NULL,
          bank_id INTEGER,
          normalized_total_due TEXT NOT NULL,
          normalized_currency TEXT NOT NULL,
          original_amount TEXT,
          original_currency TEXT,
          statement_period INTEGER,
          paid_at INTEGER,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute(
        'CREATE UNIQUE INDEX idx_bill_message ON bills (message_id)',
      );
      await db.execute(
        'CREATE INDEX idx_bill_bank_period ON bills (bank_id, statement_period)',
      );
      return db;
    }

    test('preserves messages and hand-configured accounts', () async {
      final db = await openV5();
      await db.insert('sms_records', {
        'sender': 'CHK',
        'content': 'debit 50',
        'timestamp': 1,
        'status': 'success',
        'updated_at': 1,
        'category': 'transaction',
      });
      await db.insert('banks', {
        'name': 'My Card',
        'account_type': 'credit',
        'card_digits': '4238|3241',
        'created_at': 1,
      });

      await AppDatabase.onUpgrade(db, 5, 6);

      final sms = (await db.query('sms_records')).single;
      expect(sms['sender'], 'CHK');
      expect(sms['category'], 'transaction');
      expect(sms['needs_llm'], 0); // backfilled by the column default
      final bank = (await db.query('banks')).single;
      expect(bank['name'], 'My Card');
      expect(bank['card_digits'], '4238|3241');
      await db.close();
    });

    test('lands on the same shape as a fresh v6 create', () async {
      // Every table, not just the altered one: onUpgrade silently no-ops for a
      // version pair it has no branch for, so a future migration that forgets
      // a branch leaves whichever table it meant to change behind. Checking
      // only sms_records would pass right through that.
      final migrated = await openV5();
      await AppDatabase.onUpgrade(migrated, 5, 6);
      final fresh = await openTestDb();

      for (final table in const [
        'sms_records',
        'banks',
        'transactions',
        'bills',
        'app_meta',
      ]) {
        expect(
          await _columnSpecs(migrated, table),
          await _columnSpecs(fresh, table),
          reason: 'columns of $table drifted from a fresh create',
        );
        expect(
          await _indexDdl(migrated, table),
          await _indexDdl(fresh, table),
          reason: 'indexes of $table drifted from a fresh create',
        );
      }
      await migrated.close();
      await fresh.close();
    });

    test('a version-skipping upgrade from v5 still preserves data', () async {
      // The trap this guard exists for: once _version moves past 6, a device
      // that skipped a release arrives as (5, 7) and must still migrate rather
      // than get wiped.
      final db = await openV5();
      await db.insert('banks', {
        'name': 'My Card',
        'account_type': 'credit',
        'card_digits': '4238|3241',
        'created_at': 1,
      });

      await AppDatabase.onUpgrade(db, 5, 7);

      expect((await db.query('banks')).single['name'], 'My Card');
      expect(await _columnNames(db, 'sms_records'), contains('needs_llm'));
      await db.close();
    });

    test('a pre-release version still rebuilds destructively', () async {
      final db = await openV5();
      await db.insert('sms_records', {
        'sender': 'OLD',
        'content': 'x',
        'timestamp': 1,
        'status': 'success',
        'updated_at': 1,
      });

      await AppDatabase.onUpgrade(db, 4, 6);

      expect(await db.query('sms_records'), isEmpty);
      expect(await _columnNames(db, 'sms_records'), contains('needs_llm'));
      await db.close();
    });
  });
}
