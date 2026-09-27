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
}
