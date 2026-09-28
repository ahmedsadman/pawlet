import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/models/finance/trends.dart';
import 'package:pawlet/models/finance/tx_query.dart';
import 'package:pawlet/utils/date_range.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

double _n(String s) => double.parse(s);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('transactions', () {
    test(
      'totals cover the range (type filter ignored, transfers excluded)',
      () async {
        final db = await openTestDb();
        final m1 = await insertSms(db, sender: 'BankA', ts: 1);
        final m2 = await insertSms(db, sender: 'BankB', ts: 2);
        final m3 = await insertSms(db, sender: 'BankC', ts: 3);
        await insertTx(
          db,
          messageId: m1,
          amount: '100',
          type: 'income',
          date: DateTime(2026, 3, 1),
        );
        await insertTx(
          db,
          messageId: m2,
          amount: '40',
          type: 'expense',
          date: DateTime(2026, 3, 2),
        );
        await insertTx(
          db,
          messageId: m3,
          amount: '25',
          type: 'transfer',
          date: DateTime(2026, 3, 3),
        );

        final repo = FinanceRepository(db);
        final page = (await repo.transactions(
          const TxQuery(types: [TxType.expense]),
        )).data;

        // Totals span the whole range regardless of the expense-only filter.
        expect(_n(page.totals.income), 100);
        expect(_n(page.totals.expense), 40);
        // But the listing + count honor the filter.
        expect(page.total, 1);
        expect(page.transactions.single.type, TxType.expense);
        await db.close();
      },
    );

    test('sorts by date desc by default and amount asc on request', () async {
      final db = await openTestDb();
      final m1 = await insertSms(db, sender: 'A', ts: 1);
      final m2 = await insertSms(db, sender: 'B', ts: 2);
      final m3 = await insertSms(db, sender: 'C', ts: 3);
      await insertTx(
        db,
        messageId: m1,
        amount: '100',
        type: 'income',
        date: DateTime(2026, 1, 1),
      );
      await insertTx(
        db,
        messageId: m2,
        amount: '40',
        type: 'expense',
        date: DateTime(2026, 1, 2),
      );
      await insertTx(
        db,
        messageId: m3,
        amount: '25',
        type: 'expense',
        date: DateTime(2026, 1, 3),
      );

      final repo = FinanceRepository(db);
      final byDate = (await repo.transactions(const TxQuery())).data;
      expect(byDate.transactions.map((t) => _n(t.normalizedAmount)), [
        25,
        40,
        100,
      ]);

      final byAmount = (await repo.transactions(
        const TxQuery(sortBy: 'amount', sortDir: 'asc'),
      )).data;
      expect(byAmount.transactions.map((t) => _n(t.normalizedAmount)), [
        25,
        40,
        100,
      ]);
      await db.close();
    });

    test('paginates and reports total pages', () async {
      final db = await openTestDb();
      for (var i = 0; i < 5; i++) {
        final m = await insertSms(db, sender: 'S$i', ts: i);
        await insertTx(
          db,
          messageId: m,
          amount: '$i',
          type: 'expense',
          date: DateTime(2026, 1, i + 1),
        );
      }
      final repo = FinanceRepository(db);
      final page = (await repo.transactions(
        const TxQuery(pageSize: 2, page: 1),
      )).data;
      expect(page.transactions.length, 2);
      expect(page.total, 5);
      expect(page.totalPages, 3);
      await db.close();
    });

    test('resolves bank join and paired-with message id', () async {
      final db = await openTestDb();
      final bank = await insertBank(db, name: 'City', accountType: 'deposit');
      final m4 = await insertSms(db, sender: 'D', ts: 4);
      final m5 = await insertSms(db, sender: 'E', ts: 5);
      final txD = await insertTx(
        db,
        messageId: m4,
        bankId: bank,
        amount: '50',
        type: 'transfer',
        date: DateTime(2026, 2, 1),
      );
      final txE = await insertTx(
        db,
        messageId: m5,
        amount: '50',
        type: 'transfer',
        date: DateTime(2026, 2, 1),
        pairedWithId: txD,
      );
      // Link the first side to the second.
      await db.update(
        'transactions',
        {'paired_with_id': txE},
        where: 'id = ?',
        whereArgs: [txD],
      );

      final repo = FinanceRepository(db);
      final page = (await repo.transactions(const TxQuery())).data;
      final d = page.transactions.firstWhere((t) => t.messageId == m4);
      expect(d.bankName, 'City');
      expect(d.bankAccountType, 'deposit');
      expect(d.pairedWithMessageId, m5);
      await db.close();
    });
  });

  group('summary', () {
    test('gap-fills months between range endpoints with zeros', () async {
      final db = await openTestDb();
      final jan = await insertSms(db, sender: 'A', ts: 1);
      final mar = await insertSms(db, sender: 'B', ts: 2);
      await insertTx(
        db,
        messageId: jan,
        amount: '100',
        type: 'income',
        date: DateTime(2026, 1, 10),
      );
      await insertTx(
        db,
        messageId: mar,
        amount: '60',
        type: 'expense',
        date: DateTime(2026, 3, 10),
      );

      final repo = FinanceRepository(db);
      final summary = (await repo.summary(
        DateRange(from: DateTime(2026, 1, 1), to: DateTime(2026, 3, 31)),
      )).data;

      expect(summary.series.length, 3);
      expect(summary.series[0].monthStart.month, 1);
      expect(_n(summary.series[0].income), 100);
      expect(_n(summary.series[1].income), 0); // Feb gap-filled
      expect(_n(summary.series[1].expense), 0);
      expect(_n(summary.series[2].expense), 60);
      await db.close();
    });

    test('returns an empty series when there is no activity', () async {
      final db = await openTestDb();
      final repo = FinanceRepository(db);
      final summary = (await repo.summary(const DateRange())).data;
      expect(summary.isEmpty, isTrue);
      await db.close();
    });
  });

  group('trends', () {
    test('computes recent-vs-prior averages, change and sparklines', () async {
      final db = await openTestDb();
      final now = DateTime.now();
      // Seed 6 whole months before the current partial month.
      Future<void> seed(int monthsAgo, num income, num expense) async {
        final date = DateTime(now.year, now.month - monthsAgo, 15);
        final mi = await insertSms(
          db,
          sender: 'I',
          ts: date.millisecondsSinceEpoch,
        );
        final me = await insertSms(
          db,
          sender: 'E',
          ts: date.millisecondsSinceEpoch + 1,
        );
        await insertTx(
          db,
          messageId: mi,
          amount: '$income',
          type: 'income',
          date: date,
        );
        await insertTx(
          db,
          messageId: me,
          amount: '$expense',
          type: 'expense',
          date: date,
        );
      }

      // prior window (m-6..m-4): income 100 / expense 50
      for (final k in [6, 5, 4]) {
        await seed(k, 100, 50);
      }
      // recent window (m-3..m-1): income 300 / expense 100
      for (final k in [3, 2, 1]) {
        await seed(k, 300, 100);
      }

      final repo = FinanceRepository(db);
      final trends = (await repo.trends()).data;

      expect(trends.windowMonths, 3);
      expect(trends.sparkMonths.length, 6);

      expect(_n(trends.income.recentAvg), 300);
      expect(_n(trends.income.priorAvg), 100);
      expect(_n(trends.income.changePct!), 200); // (300-100)/100*100
      expect(trends.income.direction, TrendDirection.up);
      expect(trends.income.spark.length, 6);
      expect(_n(trends.income.spark.first), 100);
      expect(_n(trends.income.spark.last), 300);

      expect(_n(trends.spend.changePct!), 100); // (100-50)/50*100

      // savings: recent (900-300)/900=0.6667, prior (300-150)/300=0.5
      expect(_n(trends.savingsRate.recent!), closeTo(0.6667, 0.0001));
      expect(_n(trends.savingsRate.prior!), 0.5);
      expect(_n(trends.savingsRate.changePp!), closeTo(16.7, 0.001));
      expect(trends.savingsRate.direction, TrendDirection.up);
      await db.close();
    });

    test('flat baseline yields a "new" direction', () async {
      final db = await openTestDb();
      final repo = FinanceRepository(db);
      final trends = (await repo.trends()).data;
      expect(trends.income.changePct, isNull);
      expect(trends.income.direction, TrendDirection.isNew);
      await db.close();
    });
  });

  group('bills', () {
    test(
      'orders newest first with linked transaction ids and paid state',
      () async {
        final db = await openTestDb();
        final bank = await insertBank(
          db,
          name: 'EBL Card',
          accountType: 'credit',
          cardDigits: '4238|3241',
        );
        final bm1 = await insertSms(db, sender: 'EBL', ts: 100);
        final bm2 = await insertSms(db, sender: 'EBL', ts: 200);
        final b1 = await insertBill(
          db,
          messageId: bm1,
          bankId: bank,
          totalDue: '8020.00',
          statementPeriod: DateTime(2026, 6, 1),
        );
        final b2 = await insertBill(
          db,
          messageId: bm2,
          bankId: bank,
          totalDue: '5000.00',
          statementPeriod: DateTime(2026, 7, 1),
          paidAt: DateTime(2026, 7, 20),
        );

        // A transaction paying bill b2.
        final pm = await insertSms(db, sender: 'City', ts: 210);
        final tx = await insertTx(
          db,
          messageId: pm,
          bankId: bank,
          billId: b2,
          amount: '5000.00',
          type: 'transfer',
          date: DateTime(2026, 7, 20),
        );

        final repo = FinanceRepository(db);
        final page = (await repo.bills(bank)).data;

        expect(page.total, 2);
        // Newest received_at first (b2 ts=200 before b1 ts=100 -> b2 first).
        expect(page.bills.first.id, b2);
        expect(page.bills.first.isPaid, isTrue);
        expect(page.bills.first.linkedTransactionIds, [tx]);
        expect(page.bills.last.id, b1);
        expect(page.bills.last.isPaid, isFalse);
        await db.close();
      },
    );
  });

  group('updateTransactionType', () {
    test('changes a stored transaction type', () async {
      final db = await openTestDb();
      final m = await insertSms(db, sender: 'A', ts: 1);
      final id = await insertTx(
        db,
        messageId: m,
        amount: '50',
        type: 'expense',
        date: DateTime(2026, 1, 1),
      );
      final repo = FinanceRepository(db);

      await repo.updateTransactionType(id, TxType.income);

      final page = (await repo.transactions(const TxQuery())).data;
      expect(page.transactions.single.type, TxType.income);
      // Aggregates recompute from the stored type: income now counts it.
      expect(_n(page.totals.income), 50);
      expect(_n(page.totals.expense), 0);
      await db.close();
    });
  });

  group('manual transactions', () {
    test(
      'lists a manual (null message_id) row with bank name as sender',
      () async {
        final db = await openTestDb();
        final bank = await insertBank(db, name: 'City', accountType: 'deposit');
        final repo = FinanceRepository(db);

        final id = await repo.insertManualTransaction(
          bankId: bank,
          amount: '250.00',
          type: TxType.expense,
          date: DateTime(2026, 5, 1),
          currency: 'BDT',
        );
        expect(id, greaterThan(0));

        final page = (await repo.transactions(const TxQuery())).data;
        final tx = page.transactions.single;
        expect(tx.messageId, isNull);
        expect(tx.bankName, 'City');
        expect(tx.sender, 'City'); // COALESCE(sms.sender, bank.name)
        expect(_n(tx.normalizedAmount), 250);
        expect(tx.type, TxType.expense);
        expect(_n(page.totals.expense), 250);
        await db.close();
      },
    );

    test(
      'insertManualTransaction falls back to repo currency when omitted',
      () async {
        final db = await openTestDb();
        final bank = await insertBank(db, name: 'City');
        final repo = FinanceRepository(db, currency: () => 'BDT');
        await repo.insertManualTransaction(
          bankId: bank,
          amount: '5.00',
          type: TxType.income,
          date: DateTime(2026, 5, 1),
        );
        final tx = (await repo.transactions(
          const TxQuery(),
        )).data.transactions.single;
        expect(tx.normalizedCurrency, 'BDT');
        await db.close();
      },
    );
  });

  group('updateTransaction', () {
    test('updates both amount and type', () async {
      final db = await openTestDb();
      final m = await insertSms(db, sender: 'A', ts: 1);
      final id = await insertTx(
        db,
        messageId: m,
        amount: '50',
        type: 'expense',
        date: DateTime(2026, 1, 1),
      );
      final repo = FinanceRepository(db);

      await repo.updateTransaction(id, amount: '75.50', type: TxType.income);

      final tx = (await repo.transactions(
        const TxQuery(),
      )).data.transactions.single;
      expect(_n(tx.normalizedAmount), 75.5);
      expect(tx.type, TxType.income);
      await db.close();
    });
  });

  group('message', () {
    test('reads the backing SMS', () async {
      final db = await openTestDb();
      final id = await insertSms(
        db,
        sender: 'BankX',
        content: 'debit 50',
        ts: 999,
      );
      final repo = FinanceRepository(db);
      final msg = (await repo.message(id)).data;
      expect(msg.sender, 'BankX');
      expect(msg.content, 'debit 50');
      expect(msg.receivedAt.millisecondsSinceEpoch, 999);
      await db.close();
    });
  });
}
