import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/database.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/services/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<SettingsRepository> settings([
    Map<String, Object> seed = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(seed);
    return SettingsRepository(await SharedPreferences.getInstance());
  }

  test('exports and restores all tables, preserving ids (replace)', () async {
    final src = await openTestDb();
    final msgId = await insertSms(src, sender: 'BRAC', content: 'hi', ts: 100);
    final bankId = await insertBank(src, name: 'BRAC Bank', createdAt: 1);
    await insertTx(
      src,
      messageId: msgId,
      bankId: bankId,
      amount: '10.00',
      type: 'expense',
      date: DateTime(2026, 1, 1),
    );
    await insertBill(src, messageId: msgId, bankId: bankId, totalDue: '5.00');

    final settingsRepo = await settings();
    final json = await BackupService(
      db: src,
      settings: settingsRepo,
    ).exportJson(nowMs: 123);

    // Destination pre-seeded with junk that restore must wipe.
    final dst = await openTestDb();
    await insertSms(dst, sender: 'JUNK', ts: 999);
    await BackupService(db: dst, settings: settingsRepo).importJson(json);

    for (final table in const [
      AppDatabase.smsTable,
      AppDatabase.banksTable,
      AppDatabase.transactionsTable,
      AppDatabase.billsTable,
    ]) {
      final want = await src.query(table, orderBy: 'id');
      final got = await dst.query(table, orderBy: 'id');
      expect(got, want, reason: 'table $table should round-trip exactly');
    }

    await src.close();
    await dst.close();
  });

  test('restore replaces settings with the backup snapshot', () async {
    final prefs = await settings({'tx_sort': 'amount', 'hide_balance': true});
    final db = await openTestDb();
    final json = await BackupService(db: db, settings: prefs).exportJson();

    await prefs.setTxSort('date'); // mutate after the snapshot
    await prefs.setHideBalance(false);

    await BackupService(db: db, settings: prefs).importJson(json);
    expect(prefs.txSort, 'amount');
    expect(prefs.hideBalance, isTrue);

    await db.close();
  });

  test('rejects an unknown backup version', () async {
    final db = await openTestDb();
    final svc = BackupService(db: db, settings: await settings());
    final bad = jsonEncode({'pawlet_backup_version': 999, 'database': {}});
    expect(() => svc.importJson(bad), throwsA(isA<BackupFormatException>()));
    await db.close();
  });

  test('rejects malformed JSON', () async {
    final db = await openTestDb();
    final svc = BackupService(db: db, settings: await settings());
    expect(
      () => svc.importJson('not json {'),
      throwsA(isA<BackupFormatException>()),
    );
    await db.close();
  });

  test('rejects a valid-version backup missing a table', () async {
    final db = await openTestDb();
    final svc = BackupService(db: db, settings: await settings());
    // Correct version but the `database` section omits the required tables.
    final bad = jsonEncode({
      'pawlet_backup_version': 1,
      'database': {AppDatabase.smsTable: <Object?>[]},
    });
    expect(() => svc.importJson(bad), throwsA(isA<BackupFormatException>()));
    await db.close();
  });

  test('clears settings when the backup omits the settings section', () async {
    final prefs = await settings({'tx_sort': 'amount', 'hide_balance': true});
    final db = await openTestDb();
    // Well-formed DB payload (all four tables empty) but no `settings` key.
    final json = jsonEncode({
      'pawlet_backup_version': 1,
      'database': {
        AppDatabase.smsTable: <Object?>[],
        AppDatabase.banksTable: <Object?>[],
        AppDatabase.transactionsTable: <Object?>[],
        AppDatabase.billsTable: <Object?>[],
      },
    });

    await BackupService(db: db, settings: prefs).importJson(json);
    // Absent settings section => managed keys reset to their defaults (replace).
    expect(prefs.txSort, isNull);
    expect(prefs.hideBalance, isFalse);

    await db.close();
  });

  test('round-trips pairing rejections', () async {
    final src = await openTestDb();
    await src.insert('pairing_rejections', {
      'tx_low': 1,
      'tx_high': 2,
      'expires_at': 99,
    });
    final settingsRepo = await settings();
    final json = await BackupService(
      db: src,
      settings: settingsRepo,
    ).exportJson(nowMs: 1);

    final dst = await openTestDb();
    await BackupService(db: dst, settings: settingsRepo).importJson(json);

    expect(await dst.query('pairing_rejections'), [
      {'tx_low': 1, 'tx_high': 2, 'expires_at': 99},
    ]);
  });

  test(
    'restores a backup without pairing rejections and clears local ones',
    () async {
      final src = await openTestDb();
      final settingsRepo = await settings();
      final exported = await BackupService(
        db: src,
        settings: settingsRepo,
      ).exportJson(nowMs: 1);
      // An export from before the table existed.
      final root = jsonDecode(exported) as Map<String, dynamic>;
      (root['database'] as Map<String, dynamic>).remove('pairing_rejections');

      final dst = await openTestDb();
      // Left over on the device; would point at unrelated restored ids.
      await dst.insert('pairing_rejections', {
        'tx_low': 7,
        'tx_high': 8,
        'expires_at': 99,
      });
      await BackupService(
        db: dst,
        settings: settingsRepo,
      ).importJson(jsonEncode(root));

      expect(await dst.query('pairing_rejections'), isEmpty);
    },
  );

  test('rejects a pairing rejections section that is not a list', () async {
    final src = await openTestDb();
    final settingsRepo = await settings();
    final exported = await BackupService(
      db: src,
      settings: settingsRepo,
    ).exportJson(nowMs: 1);
    final root = jsonDecode(exported) as Map<String, dynamic>;
    (root['database'] as Map<String, dynamic>)['pairing_rejections'] = 'oops';

    final dst = await openTestDb();
    await expectLater(
      BackupService(
        db: dst,
        settings: settingsRepo,
      ).importJson(jsonEncode(root)),
      throwsA(isA<BackupFormatException>()),
    );
  });

  test('a backup from before status_overridden restores it as 0', () async {
    final src = await openTestDb();
    final msgId = await insertSms(src, sender: 'EBL', ts: 100);
    await insertBill(src, messageId: msgId, totalDue: '5.00');
    final settingsRepo = await settings();
    final root =
        jsonDecode(
              await BackupService(db: src, settings: settingsRepo).exportJson(),
            )
            as Map<String, Object?>;
    // Simulate a pre-v10 export: drop the column from every bill row.
    final bills = ((root['database'] as Map)['bills'] as List)
        .cast<Map<String, Object?>>();
    for (final row in bills) {
      row.remove('status_overridden');
    }

    final dst = await openTestDb();
    await BackupService(
      db: dst,
      settings: settingsRepo,
    ).importJson(jsonEncode(root));

    expect((await dst.query('bills')).single['status_overridden'], 0);
    await src.close();
    await dst.close();
  });

  test('round-trips a user-overridden bill', () async {
    final src = await openTestDb();
    final msgId = await insertSms(src, sender: 'EBL', ts: 100);
    await insertBill(
      src,
      messageId: msgId,
      totalDue: '5.00',
      statusOverridden: true,
    );
    final settingsRepo = await settings();
    final json = await BackupService(
      db: src,
      settings: settingsRepo,
    ).exportJson();

    final dst = await openTestDb();
    await BackupService(db: dst, settings: settingsRepo).importJson(json);

    expect((await dst.query('bills')).single['status_overridden'], 1);
    await src.close();
    await dst.close();
  });
}
