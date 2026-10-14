import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/finance/bill_actions.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const nowMs = 1000;
  late Database db;
  late BillActions actions;
  late int card, bill;

  setUp(() async {
    db = await openTestDb();
    actions = BillActions(db, nowMs: () => nowMs);
    card = await insertBank(
      db,
      name: 'EBL',
      accountType: 'credit',
      cardDigits: '4238|1234',
    );
    final msg = await insertSms(db, sender: 'EBL', ts: 1);
    bill = await insertBill(db, messageId: msg, bankId: card, totalDue: '50');
  });

  tearDown(() => db.close());

  Future<Map<String, Object?>> billRow() async =>
      (await db.query('bills', where: 'id = ?', whereArgs: [bill])).single;

  Future<Object?> billIdOf(int txId) async => (await db.query(
    'transactions',
    where: 'id = ?',
    whereArgs: [txId],
  )).single['bill_id'];

  test('marking paid stamps now and overrides the status', () async {
    await actions.setPaid(bill, paid: true);

    final row = await billRow();
    expect(row['paid_at'], nowMs);
    expect(row['status_overridden'], 1);
  });

  test('marking an already-paid bill paid keeps its paid date', () async {
    await db.update(
      'bills',
      {'paid_at': 7},
      where: 'id = ?',
      whereArgs: [bill],
    );

    await actions.setPaid(bill, paid: true);

    expect((await billRow())['paid_at'], 7);
  });

  test('marking unpaid clears paid_at and unlinks both payment legs', () async {
    final m1 = await insertSms(db, sender: 'MTB', ts: 2);
    final m2 = await insertSms(db, sender: 'EBL', ts: 3);
    final out = await insertTx(
      db,
      messageId: m1,
      billId: bill,
      amount: '50',
      type: 'transfer',
      date: DateTime(2026, 7, 8),
    );
    final leg = await insertTx(
      db,
      messageId: m2,
      bankId: card,
      billId: bill,
      amount: '50',
      type: 'transfer',
      date: DateTime(2026, 7, 8),
    );
    await db.update(
      'bills',
      {'paid_at': 7},
      where: 'id = ?',
      whereArgs: [bill],
    );

    await actions.setPaid(bill, paid: false);

    final row = await billRow();
    expect(row['paid_at'], isNull);
    expect(row['status_overridden'], 1);
    expect(await billIdOf(out), isNull);
    expect(await billIdOf(leg), isNull);
  });

  test('marking unpaid twice is harmless', () async {
    await actions.setPaid(bill, paid: false);
    await actions.setPaid(bill, paid: false);

    final row = await billRow();
    expect(row['paid_at'], isNull);
    expect(row['status_overridden'], 1);
  });
}
