import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/pairing_suggestion.dart';
import 'package:pawlet/services/finance/finance_matcher.dart';
import 'package:pawlet/services/finance/pairing_actions.dart';
import 'package:pawlet/services/finance/pairing_suggester.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final now = DateTime(2026, 10, 14, 12);
  DateTime ago(Duration d) => now.subtract(d);

  late Database db;
  late PairingActions actions;
  late int mtb, city, ebl;
  var msg = 100;

  setUp(() async {
    db = await openTestDb();
    actions = PairingActions(db);
    mtb = await insertBank(db, name: 'MTB');
    city = await insertBank(db, name: 'City Bank');
    ebl = await insertBank(
      db,
      name: 'EBL',
      accountType: 'credit',
      cardDigits: '4238|1234',
    );
  });

  tearDown(() => db.close());

  Future<int> tx(int bankId, String type, String amount, DateTime date) =>
      insertTx(
        db,
        messageId: ++msg,
        bankId: bankId,
        amount: amount,
        type: type,
        date: date,
      );

  Future<Map<String, Object?>> row(int id) async =>
      (await db.query('transactions', where: 'id = ?', whereArgs: [id])).first;

  Future<PairingSuggestion> only() async => (await PairingSuggester(
    db,
  ).suggest(nowMs: now.millisecondsSinceEpoch)).single;

  Future<(int, int)> transferPair() async {
    final out = await tx(mtb, 'expense', '1500', ago(const Duration(hours: 5)));
    final inc = await tx(city, 'income', '1500', ago(const Duration(hours: 3)));
    return (out, inc);
  }

  Future<(int, int, int)> cardPairWithBill() async {
    final billMsg = await insertSms(
      db,
      sender: 'EBL',
      ts: ago(const Duration(days: 10)).millisecondsSinceEpoch,
    );
    final bill = await insertBill(
      db,
      messageId: billMsg,
      bankId: ebl,
      totalDue: '2951',
    );
    final out = await tx(mtb, 'expense', '2951', ago(const Duration(days: 3)));
    final card = await tx(
      ebl,
      'transfer',
      '2951',
      ago(const Duration(days: 2)),
    );
    return (out, card, bill);
  }

  test('accepting a transfer pairs both rows as transfers', () async {
    final (out, inc) = await transferPair();

    final d = await actions.accept(await only());

    expect(d, isNotNull);
    expect(d!.accepted, isTrue);
    expect((await row(out))['type'], 'transfer');
    expect((await row(out))['paired_with_id'], inc);
    expect((await row(inc))['type'], 'transfer');
    expect((await row(inc))['paired_with_id'], out);
  });

  test('accepting a card payment pairs and links the bill', () async {
    final (out, card, bill) = await cardPairWithBill();

    final d = await actions.accept(await only());

    expect(d!.linkedBillId, bill);
    expect((await row(out))['type'], 'transfer');
    expect((await row(out))['paired_with_id'], card);
    expect((await row(card))['type'], 'transfer');
    expect((await row(card))['paired_with_id'], out);
    expect((await row(out))['bill_id'], bill);
    expect((await row(card))['bill_id'], bill);
    final paidAt = (await db.query('bills')).single['paid_at'];
    expect(paidAt, ago(const Duration(days: 2)).millisecondsSinceEpoch);
  });

  test('accept writes nothing when a leg changed meanwhile', () async {
    final (out, inc) = await transferPair();
    final s = await only();
    await db.update(
      'transactions',
      {'paired_with_id': 999},
      where: 'id = ?',
      whereArgs: [inc],
    );

    expect(await actions.accept(s), isNull);
    expect((await row(out))['type'], 'expense');
    expect((await row(out))['paired_with_id'], isNull);
    expect((await row(inc))['type'], 'income');
    expect((await row(inc))['paired_with_id'], 999);
  });

  test(
    'accept writes nothing when the card leg got paired meanwhile',
    () async {
      final (out, card, _) = await cardPairWithBill();
      final s = await only();
      await db.update(
        'transactions',
        {'paired_with_id': 999},
        where: 'id = ?',
        whereArgs: [card],
      );

      expect(await actions.accept(s), isNull);
      expect((await row(out))['type'], 'expense');
      expect((await row(out))['paired_with_id'], isNull);
      expect((await row(out))['bill_id'], isNull);
      expect((await row(card))['paired_with_id'], 999);
      expect((await row(card))['bill_id'], isNull);
      expect((await db.query('bills')).single['paid_at'], isNull);
    },
  );

  test('accept copies an existing card bill link to the bank leg', () async {
    final (out, card, bill) = await cardPairWithBill();
    await FinanceMatcher(
      db,
      nowMs: () => now.millisecondsSinceEpoch,
    ).runPending();
    expect((await row(card))['bill_id'], bill);
    final paidAt = (await db.query('bills')).single['paid_at'];
    expect(paidAt, isNotNull);

    final d = await actions.accept(await only());

    expect(d!.linkedBillId, isNull);
    expect((await row(out))['type'], 'transfer');
    expect((await row(out))['paired_with_id'], card);
    expect((await row(out))['bill_id'], bill);
    expect((await row(card))['bill_id'], bill);
    expect((await db.query('bills')).single['paid_at'], paidAt);

    await actions.undo(d);

    expect((await row(out))['type'], 'expense');
    expect((await row(out))['paired_with_id'], isNull);
    expect((await row(out))['bill_id'], isNull);
    expect((await row(card))['paired_with_id'], isNull);
    expect((await row(card))['bill_id'], bill);
    expect((await db.query('bills')).single['paid_at'], paidAt);
  });

  test('rejecting stores the pair until 30 days after its newer leg', () async {
    await transferPair();
    final s = await only();

    final d = await actions.reject(s);

    expect(d.accepted, isFalse);
    expect(await db.query('pairing_rejections'), [
      {
        'tx_low': s.lowId,
        'tx_high': s.highId,
        'expires_at': ago(
          const Duration(hours: 3),
        ).add(const Duration(days: 30)).millisecondsSinceEpoch,
      },
    ]);
    expect(
      await PairingSuggester(db).suggest(nowMs: now.millisecondsSinceEpoch),
      isEmpty,
    );
  });

  test('undoing an accepted transfer restores both rows', () async {
    final (out, inc) = await transferPair();
    final d = await actions.accept(await only());

    await actions.undo(d!);

    expect((await row(out))['type'], 'expense');
    expect((await row(out))['paired_with_id'], isNull);
    expect((await row(inc))['type'], 'income');
    expect((await row(inc))['paired_with_id'], isNull);
  });

  test('undoing an accepted card payment unlinks its bill', () async {
    final (out, card, _) = await cardPairWithBill();
    final d = await actions.accept(await only());

    await actions.undo(d!);

    expect((await row(out))['type'], 'expense');
    expect((await row(out))['paired_with_id'], isNull);
    expect((await row(out))['bill_id'], isNull);
    expect((await row(card))['type'], 'transfer');
    expect((await row(card))['paired_with_id'], isNull);
    expect((await row(card))['bill_id'], isNull);
    expect((await db.query('bills')).single['paid_at'], isNull);
  });

  test(
    'undo leaves the legs alone once they stop pointing at each other',
    () async {
      final (out, inc) = await transferPair();
      final d = await actions.accept(await only());
      await db.update(
        'transactions',
        {'paired_with_id': 999},
        where: 'id = ?',
        whereArgs: [inc],
      );

      await actions.undo(d!);

      expect((await row(out))['type'], 'transfer');
      expect((await row(out))['paired_with_id'], inc);
      expect((await row(inc))['type'], 'transfer');
      expect((await row(inc))['paired_with_id'], 999);
    },
  );

  test('undoing a rejection deletes it', () async {
    await transferPair();
    final d = await actions.reject(await only());

    await actions.undo(d);

    expect(await db.query('pairing_rejections'), isEmpty);
  });

  test('accepting a card payment leaves an overridden bill alone', () async {
    final (out, card, bill) = await cardPairWithBill();
    await db.update(
      'bills',
      {'status_overridden': 1},
      where: 'id = ?',
      whereArgs: [bill],
    );

    final d = await actions.accept(await only());

    expect(d!.linkedBillId, isNull);
    expect((await row(out))['paired_with_id'], card);
    expect((await row(card))['bill_id'], isNull);
    expect((await row(out))['bill_id'], isNull);
    expect((await db.query('bills')).single['paid_at'], isNull);
  });

  test(
    'undo leaves an overridden bill paid_at alone while unpairing',
    () async {
      final (out, card, bill) = await cardPairWithBill();
      final d = await actions.accept(await only());
      final billPaidAt = (await db.query('bills')).single['paid_at'];
      await db.update(
        'bills',
        {'status_overridden': 1},
        where: 'id = ?',
        whereArgs: [bill],
      );

      await actions.undo(d!);

      expect((await row(out))['type'], 'expense');
      expect((await row(out))['paired_with_id'], isNull);
      expect((await row(out))['bill_id'], isNull);
      expect((await row(card))['type'], 'transfer');
      expect((await row(card))['paired_with_id'], isNull);
      expect((await row(card))['bill_id'], isNull);
      expect((await db.query('bills')).single['paid_at'], billPaidAt);
    },
  );
}
