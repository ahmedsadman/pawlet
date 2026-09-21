import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/banks_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('BanksRepository', () {
    test('create, list, getById in insertion order', () async {
      final database = await openTestDb();
      var clock = 1000;
      final r = BanksRepository(database, nowMs: () => clock);

      final deposit = await r.create(
        name: 'BRAC Bank',
        accountType: 'deposit',
        lastBalance: '2000.00',
        lastBalanceAt: 1000,
      );
      clock = 2000;
      final credit = await r.create(
        name: 'EBL Card',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );

      expect(deposit.isDeposit, isTrue);
      expect(deposit.lastBalance, '2000.00');
      expect(credit.isCredit, isTrue);
      expect(credit.last4, '3241');

      final all = await r.list();
      expect(all.map((b) => b.name), ['BRAC Bank', 'EBL Card']);

      final fetched = await r.getById(credit.id);
      expect(fetched!.name, 'EBL Card');
      await database.close();
    });

    test('update mutates fields and clears balance', () async {
      final database = await openTestDb();
      final r = BanksRepository(database, nowMs: () => 1);
      final bank = await r.create(name: 'City', lastBalance: '500.00');

      final renamed = await r.update(bank.id, name: 'City Bank');
      expect(renamed!.name, 'City Bank');
      expect(renamed.lastBalance, '500.00');

      final cleared = await r.update(bank.id, clearLastBalance: true);
      expect(cleared!.lastBalance, isNull);
      await database.close();
    });

    test('delete removes the row', () async {
      final database = await openTestDb();
      final r = BanksRepository(database, nowMs: () => 1);
      final bank = await r.create(name: 'Temp');
      await r.delete(bank.id);
      expect(await r.getById(bank.id), isNull);
      expect(await r.list(), isEmpty);
      await database.close();
    });
  });
}
