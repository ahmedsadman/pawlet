import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/banks_repository.dart';
import 'package:meowni/models/sms_record.dart';
import 'package:meowni/services/classification/classifier.dart';
import 'package:meowni/services/finance/finance_writer.dart';
import 'package:meowni/services/llm/llm_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

const _feb = 1770000000000; // fixed "recent" epoch ms
const _jan = 1767000000000; // fixed "older" epoch ms

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<SmsRecord> seedSms(
    db, {
    required String sender,
    required String content,
    int ts = _feb,
  }) async {
    final id = await insertSms(db, sender: sender, content: content, ts: ts);
    return SmsRecord(id: id, sender: sender, content: content, timestamp: ts);
  }

  ClassificationOutcome tx(MetadataResult m) =>
      ClassificationOutcome(category: SmsCategory.transaction, transaction: m, llmInvoked: true);
  ClassificationOutcome bill(BillMetadataResult b) =>
      ClassificationOutcome(category: SmsCategory.bill, bill: b, llmInvoked: true);

  group('transactions', () {
    test('records a transaction, matches the bank by name, updates balance', () async {
      final db = await openTestDb();
      final checking = await BanksRepository(db).create(
        name: 'Checking',
        lastBalance: '1000.00',
        lastBalanceAt: _jan,
      );
      final rec = await seedSms(db, sender: 'CHK', content: 'debit 50');
      final cat = await FinanceWriter(db, nowMs: () => 0).apply(
        record: rec,
        outcome: tx(const MetadataResult(
          bank: 'Checking',
          balance: '1950.00',
          amount: '50',
          originalAmount: '50',
          transactionType: 'expense',
          originalCurrency: 'BDT',
        )),
        banks: [checking],
        currency: 'BDT',
      );

      expect(cat, 'transaction');
      final rows = await db.query('transactions');
      expect(rows.length, 1);
      expect(rows.first['bank_id'], checking.id);
      expect(rows.first['type'], 'expense');
      final bank = (await db.query('banks', where: 'id = ?', whereArgs: [checking.id])).first;
      expect(bank['last_balance'], '1950.00'); // newer timestamp → updated
      await db.close();
    });

    test('dedupes by message_id', () async {
      final db = await openTestDb();
      final checking = await BanksRepository(db).create(name: 'Checking');
      final rec = await seedSms(db, sender: 'CHK', content: 'debit 50');
      final w = FinanceWriter(db, nowMs: () => 0);
      final m = tx(const MetadataResult(
        bank: 'Checking',
        amount: '50',
        originalAmount: '50',
        transactionType: 'expense',
        originalCurrency: 'BDT',
      ));
      expect(await w.apply(record: rec, outcome: m, banks: [checking], currency: 'BDT'), 'transaction');
      expect(await w.apply(record: rec, outcome: m, banks: [checking], currency: 'BDT'), 'ignored');
      expect((await db.query('transactions')).length, 1);
      await db.close();
    });

    test('matches a credit card by digits in the content', () async {
      final db = await openTestDb();
      final ebl = await BanksRepository(db).create(
        name: 'EBL Card',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final rec = await seedSms(db, sender: 'RANDOM', content: 'purchase 4238****3241 for 200');
      await FinanceWriter(db, nowMs: () => 0).apply(
        record: rec,
        outcome: tx(const MetadataResult(
          amount: '200',
          originalAmount: '200',
          transactionType: 'expense',
          originalCurrency: 'BDT',
        )),
        banks: [ebl],
        currency: 'BDT',
      );
      expect((await db.query('transactions')).first['bank_id'], ebl.id);
      await db.close();
    });

    test('skips balance update on currency mismatch / credit / older ts', () async {
      final db = await openTestDb();
      final repo = BanksRepository(db);
      final deposit = await repo.create(name: 'Dep', lastBalance: '100.00', lastBalanceAt: _feb);
      final credit = await repo.create(name: 'Cred', accountType: 'credit', cardDigits: '1111|2222');
      final w = FinanceWriter(db, nowMs: () => 0);

      // Currency mismatch → no update.
      await w.apply(
        record: await seedSms(db, sender: 'DEP', content: 'x'),
        outcome: tx(const MetadataResult(bank: 'Dep', balance: '999.00', amount: '5', originalAmount: '5', transactionType: 'expense', originalCurrency: 'USD')),
        banks: [deposit],
        currency: 'BDT',
      );
      var dep = (await db.query('banks', where: 'id = ?', whereArgs: [deposit.id])).first;
      expect(dep['last_balance'], '100.00');

      // Older timestamp than last_balance_at → no update.
      await w.apply(
        record: await seedSms(db, sender: 'DEP', content: 'y', ts: _jan),
        outcome: tx(const MetadataResult(bank: 'Dep', balance: '5.00', amount: '5', originalAmount: '5', transactionType: 'expense', originalCurrency: 'BDT')),
        banks: [deposit],
        currency: 'BDT',
      );
      dep = (await db.query('banks', where: 'id = ?', whereArgs: [deposit.id])).first;
      expect(dep['last_balance'], '100.00');

      // Credit account → never updates balance (stays null).
      await w.apply(
        record: await seedSms(db, sender: 'CRD', content: '1111 2222'),
        outcome: tx(const MetadataResult(bank: 'Cred', balance: '50.00', amount: '5', originalAmount: '5', transactionType: 'expense', originalCurrency: 'BDT')),
        banks: [credit],
        currency: 'BDT',
      );
      final crd = (await db.query('banks', where: 'id = ?', whereArgs: [credit.id])).first;
      expect(crd['last_balance'], isNull);
      await db.close();
    });

    test('a transaction with no amount records nothing', () async {
      final db = await openTestDb();
      final checking = await BanksRepository(db).create(name: 'Checking');
      final rec = await seedSms(db, sender: 'CHK', content: 'balance is 100');
      final cat = await FinanceWriter(db, nowMs: () => 0).apply(
        record: rec,
        outcome: tx(const MetadataResult(bank: 'Checking', balance: '100')),
        banks: [checking],
        currency: 'BDT',
      );
      expect(cat, 'ignored');
      expect(await db.query('transactions'), isEmpty);
      await db.close();
    });
  });

  group('bills (strict)', () {
    final billMeta = const BillMetadataResult(
      normalizedTotalDue: '8020',
      originalAmount: '8020',
      originalCurrency: 'BDT',
      statementMonth: 7,
      statementYear: 2026,
    );

    test('records a bill only when the card digits appear in the content', () async {
      final db = await openTestDb();
      final ebl = await BanksRepository(db).create(
        name: 'EBL Card',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final rec = await seedSms(db, sender: 'EBL', content: 'Monthly bill 4238****3241 Total Due 8020');
      final cat = await FinanceWriter(db, nowMs: () => 0)
          .apply(record: rec, outcome: bill(billMeta), banks: [ebl], currency: 'BDT');
      expect(cat, 'bill');
      final rows = await db.query('bills');
      expect(rows.length, 1);
      expect(rows.first['bank_id'], ebl.id);
      await db.close();
    });

    test('ignores a bill with no matching card digits', () async {
      final db = await openTestDb();
      final ebl = await BanksRepository(db).create(
        name: 'EBL Card',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final rec = await seedSms(db, sender: 'EBL', content: 'Your statement is ready, total due 8020');
      final cat = await FinanceWriter(db, nowMs: () => 0)
          .apply(record: rec, outcome: bill(billMeta), banks: [ebl], currency: 'BDT');
      expect(cat, 'ignored');
      expect(await db.query('bills'), isEmpty);
      await db.close();
    });

    test('de-dupes a re-sent statement for the same card + period', () async {
      final db = await openTestDb();
      final ebl = await BanksRepository(db).create(
        name: 'EBL Card',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final w = FinanceWriter(db, nowMs: () => 0);
      final first = await seedSms(db, sender: 'EBL', content: 'bill 4238****3241 due 8020');
      expect(await w.apply(record: first, outcome: bill(billMeta), banks: [ebl], currency: 'BDT'), 'bill');

      final resend = await seedSms(
        db,
        sender: 'EBL',
        content: 'reminder 4238****3241 due 8020',
        ts: _feb + 1000,
      );
      expect(await w.apply(record: resend, outcome: bill(billMeta), banks: [ebl], currency: 'BDT'), 'bill');
      expect((await db.query('bills')).length, 1); // same period → no new row
      await db.close();
    });
  });
}
