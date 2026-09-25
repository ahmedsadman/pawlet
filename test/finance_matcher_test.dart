import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/finance/finance_matcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  var msgCounter = 0;
  int nextMsg() => ++msgCounter;

  Future<int> tx(
    db, {
    int? bankId,
    int? pairedWithId,
    int? billId,
    required String amount,
    required String type,
    required DateTime date,
  }) => insertTx(
    db,
    messageId: nextMsg(),
    bankId: bankId,
    pairedWithId: pairedWithId,
    billId: billId,
    amount: amount,
    type: type,
    date: date,
  );

  Future<Map<String, Object?>> txRow(db, int id) async =>
      (await db.query('transactions', where: 'id = ?', whereArgs: [id])).first;

  group('transfer pairing', () {
    test('pairs a transfer with the closest matching expense', () async {
      final db = await openTestDb();
      final t = DateTime(2026, 7, 1, 12, 0);
      final transfer = await tx(db, amount: '5000', type: 'transfer', date: t);
      final expense = await tx(
        db,
        amount: '5000',
        type: 'expense',
        date: t.add(const Duration(minutes: 5)),
      );

      expect(await findAndPairTransferCounterpart(db, transfer), expense);
      final tr = await txRow(db, transfer);
      final ex = await txRow(db, expense);
      expect(tr['paired_with_id'], expense);
      expect(ex['paired_with_id'], transfer);
      expect(ex['type'], 'transfer'); // flipped from expense
      await db.close();
    });

    test('honors the ±1.00 amount tolerance', () async {
      final db = await openTestDb();
      final t = DateTime(2026, 7, 1, 12, 0);
      final transfer = await tx(
        db,
        amount: '5000.00',
        type: 'transfer',
        date: t,
      );
      await tx(
        db,
        amount: '5001.01',
        type: 'expense',
        date: t.add(const Duration(minutes: 1)),
      );
      expect(await findAndPairTransferCounterpart(db, transfer), isNull);

      final within = await tx(
        db,
        amount: '5001.00',
        type: 'expense',
        date: t.add(const Duration(minutes: 2)),
      );
      expect(await findAndPairTransferCounterpart(db, transfer), within);
      await db.close();
    });

    test('does not pair outside the ±15 min window', () async {
      final db = await openTestDb();
      final t = DateTime(2026, 7, 1, 12, 0);
      final transfer = await tx(db, amount: '5000', type: 'transfer', date: t);
      await tx(
        db,
        amount: '5000',
        type: 'expense',
        date: t.add(const Duration(minutes: 16)),
      );
      expect(await findAndPairTransferCounterpart(db, transfer), isNull);
      await db.close();
    });

    test('skips an ambiguous (equidistant) match', () async {
      final db = await openTestDb();
      final t = DateTime(2026, 7, 1, 12, 0);
      final transfer = await tx(db, amount: '5000', type: 'transfer', date: t);
      await tx(
        db,
        amount: '5000',
        type: 'expense',
        date: t.subtract(const Duration(minutes: 5)),
      );
      await tx(
        db,
        amount: '5000',
        type: 'expense',
        date: t.add(const Duration(minutes: 5)),
      );
      expect(await findAndPairTransferCounterpart(db, transfer), isNull);
      // Neither expense was flipped.
      final expenses = await db.query(
        'transactions',
        where: "type = 'expense'",
      );
      expect(expenses.length, 2);
      await db.close();
    });
  });

  group('bill-payment linking', () {
    test(
      'links a bill to its paying transfer (and the paired counterpart)',
      () async {
        final db = await openTestDb();
        final ebl = await insertBank(
          db,
          name: 'EBL',
          accountType: 'credit',
          cardDigits: '4238|3241',
        );
        final billMsg = await insertSms(
          db,
          sender: 'EBL',
          ts: DateTime(2026, 7, 5).millisecondsSinceEpoch,
        );
        final bill = await insertBill(
          db,
          messageId: billMsg,
          bankId: ebl,
          totalDue: '8020',
        );

        final pay = DateTime(2026, 7, 8, 10, 0);
        final expense = await tx(
          db,
          bankId: null,
          amount: '8020',
          type: 'transfer',
          date: pay,
        );
        final transfer = await tx(
          db,
          bankId: ebl,
          pairedWithId: expense,
          amount: '8020',
          type: 'transfer',
          date: pay,
        );
        // Mirror the pairing.
        await db.update(
          'transactions',
          {'paired_with_id': transfer},
          where: 'id = ?',
          whereArgs: [expense],
        );

        expect(await findAndLinkBillForPayment(db, transfer), bill);
        expect((await txRow(db, transfer))['bill_id'], bill);
        expect(
          (await txRow(db, expense))['bill_id'],
          bill,
        ); // counterpart linked too
        final billRow = (await db.query(
          'bills',
          where: 'id = ?',
          whereArgs: [bill],
        )).first;
        expect(billRow['paid_at'], pay.millisecondsSinceEpoch);
        await db.close();
      },
    );

    test(
      'links a payment to a pre-existing bill (symmetric entry point)',
      () async {
        final db = await openTestDb();
        final ebl = await insertBank(
          db,
          name: 'EBL',
          accountType: 'credit',
          cardDigits: '4238|3241',
        );
        final billMsg = await insertSms(
          db,
          sender: 'EBL',
          ts: DateTime(2026, 7, 5).millisecondsSinceEpoch,
        );
        final bill = await insertBill(
          db,
          messageId: billMsg,
          bankId: ebl,
          totalDue: '8020',
        );
        final transfer = await tx(
          db,
          bankId: ebl,
          amount: '8020',
          type: 'transfer',
          date: DateTime(2026, 7, 8),
        );

        expect(await findAndLinkPaymentForBill(db, bill), transfer);
        expect((await txRow(db, transfer))['bill_id'], bill);
        await db.close();
      },
    );
  });

  group('bill-linking edge cases', () {
    test('prefers a bill received before the payment', () async {
      final db = await openTestDb();
      final ebl = await insertBank(
        db,
        name: 'EBL',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final pay = DateTime(2026, 7, 10);
      final beforeMsg = await insertSms(
        db,
        sender: 'EBL',
        content: 'a',
        ts: pay.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      );
      final afterMsg = await insertSms(
        db,
        sender: 'EBL',
        content: 'b',
        ts: pay.add(const Duration(days: 2)).millisecondsSinceEpoch,
      );
      final billBefore = await insertBill(
        db,
        messageId: beforeMsg,
        bankId: ebl,
        totalDue: '8020',
      );
      await insertBill(db, messageId: afterMsg, bankId: ebl, totalDue: '8020');
      final transfer = await tx(
        db,
        bankId: ebl,
        amount: '8020',
        type: 'transfer',
        date: pay,
      );

      expect(await findAndLinkBillForPayment(db, transfer), billBefore);
      await db.close();
    });

    test('prefers a payment at/after the bill', () async {
      final db = await openTestDb();
      final ebl = await insertBank(
        db,
        name: 'EBL',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final billMsg = await insertSms(
        db,
        sender: 'EBL',
        ts: DateTime(2026, 7, 10).millisecondsSinceEpoch,
      );
      final bill = await insertBill(
        db,
        messageId: billMsg,
        bankId: ebl,
        totalDue: '8020',
      );
      await tx(
        db,
        bankId: ebl,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 8),
      );
      final after = await tx(
        db,
        bankId: ebl,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 12),
      );

      expect(await findAndLinkPaymentForBill(db, bill), after);
      await db.close();
    });

    test('does not link across a currency mismatch', () async {
      final db = await openTestDb();
      final ebl = await insertBank(
        db,
        name: 'EBL',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final billMsg = await insertSms(
        db,
        sender: 'EBL',
        ts: DateTime(2026, 7, 10).millisecondsSinceEpoch,
      );
      final bill = await insertBill(
        db,
        messageId: billMsg,
        bankId: ebl,
        totalDue: '8020',
        currency: 'USD',
      );
      await tx(
        db,
        bankId: ebl,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 11),
      ); // BDT
      expect(await findAndLinkPaymentForBill(db, bill), isNull);
      await db.close();
    });

    test('a transfer on a non-credit bank does not link to a bill', () async {
      final db = await openTestDb();
      final dep = await insertBank(db, name: 'Dep', accountType: 'deposit');
      final transfer = await tx(
        db,
        bankId: dep,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 10),
      );
      expect(await findAndLinkBillForPayment(db, transfer), isNull);
      await db.close();
    });

    test('skips a bill that already has a linked transaction', () async {
      final db = await openTestDb();
      final ebl = await insertBank(
        db,
        name: 'EBL',
        accountType: 'credit',
        cardDigits: '4238|3241',
      );
      final billMsg = await insertSms(
        db,
        sender: 'EBL',
        ts: DateTime(2026, 7, 10).millisecondsSinceEpoch,
      );
      final bill = await insertBill(
        db,
        messageId: billMsg,
        bankId: ebl,
        totalDue: '8020',
      );
      await tx(
        db,
        bankId: ebl,
        billId: bill,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 11),
      );
      final second = await tx(
        db,
        bankId: ebl,
        amount: '8020',
        type: 'transfer',
        date: DateTime(2026, 7, 11),
      );
      expect(await findAndLinkBillForPayment(db, second), isNull);
      await db.close();
    });
  });

  test('runPending is idempotent across repeated passes', () async {
    final db = await openTestDb();
    final now = DateTime(2026, 7, 10, 12, 0);
    final ebl = await insertBank(
      db,
      name: 'EBL',
      accountType: 'credit',
      cardDigits: '4238|3241',
    );
    final billMsg = await insertSms(
      db,
      sender: 'EBL',
      ts: DateTime(2026, 7, 7).millisecondsSinceEpoch,
    );
    final bill = await insertBill(
      db,
      messageId: billMsg,
      bankId: ebl,
      totalDue: '8020',
    );
    final pay = now.subtract(const Duration(minutes: 10));
    final transfer = await tx(
      db,
      bankId: ebl,
      amount: '8020',
      type: 'transfer',
      date: pay,
    );
    await tx(
      db,
      amount: '8020',
      type: 'expense',
      date: pay.add(const Duration(minutes: 5)),
    );

    final matcher = FinanceMatcher(db, nowMs: () => now.millisecondsSinceEpoch);
    await matcher.runPending();
    await matcher.runPending(); // second pass must not change anything or throw

    expect((await txRow(db, transfer))['bill_id'], bill);
    expect(
      (await db.query(
        'bills',
        where: 'id = ?',
        whereArgs: [bill],
      )).first['paid_at'],
      pay.millisecondsSinceEpoch,
    );
    await db.close();
  });

  test('runPending pairs and links in one sweep', () async {
    final db = await openTestDb();
    final now = DateTime(2026, 7, 10, 12, 0);
    final ebl = await insertBank(
      db,
      name: 'EBL',
      accountType: 'credit',
      cardDigits: '4238|3241',
    );
    final billMsg = await insertSms(
      db,
      sender: 'EBL',
      ts: DateTime(2026, 7, 7).millisecondsSinceEpoch,
    );
    final bill = await insertBill(
      db,
      messageId: billMsg,
      bankId: ebl,
      totalDue: '8020',
    );

    final pay = now.subtract(const Duration(minutes: 10));
    final transfer = await tx(
      db,
      bankId: ebl,
      amount: '8020',
      type: 'transfer',
      date: pay,
    );
    final expense = await tx(
      db,
      amount: '8020',
      type: 'expense',
      date: pay.add(const Duration(minutes: 5)),
    );

    await FinanceMatcher(
      db,
      nowMs: () => now.millisecondsSinceEpoch,
    ).runPending();

    final tr = await txRow(db, transfer);
    final ex = await txRow(db, expense);
    expect(tr['paired_with_id'], expense);
    expect(ex['type'], 'transfer');
    expect(tr['bill_id'], bill);
    expect(ex['bill_id'], bill);
    expect(
      (await db.query(
        'bills',
        where: 'id = ?',
        whereArgs: [bill],
      )).first['paid_at'],
      pay.millisecondsSinceEpoch,
    );
    await db.close();
  });
}
