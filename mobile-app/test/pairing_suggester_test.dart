import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/pairing_suggestion.dart';
import 'package:pawlet/services/finance/finance_matcher.dart';
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
  late int mtb, city, dbbl, ebl;
  var msg = 0;

  setUp(() async {
    db = await openTestDb();
    mtb = await insertBank(db, name: 'MTB');
    city = await insertBank(db, name: 'City Bank');
    dbbl = await insertBank(db, name: 'DBBL');
    ebl = await insertBank(
      db,
      name: 'EBL',
      accountType: 'credit',
      cardDigits: '4238|1234',
    );
  });

  tearDown(() => db.close());

  Future<int> tx(
    int bankId,
    String type,
    String amount,
    DateTime date, {
    String currency = 'BDT',
    int? pairedWithId,
  }) => insertTx(
    db,
    messageId: ++msg,
    bankId: bankId,
    pairedWithId: pairedWithId,
    amount: amount,
    currency: currency,
    type: type,
    date: date,
  );

  Future<List<PairingSuggestion>> suggest() =>
      PairingSuggester(db).suggest(nowMs: now.millisecondsSinceEpoch);

  group('transfer candidates', () {
    test('pairs an expense and an income on two deposit accounts', () async {
      final out = await tx(
        mtb,
        'expense',
        '1510',
        ago(const Duration(hours: 5)),
      );
      final inc = await tx(
        city,
        'income',
        '1500',
        ago(const Duration(hours: 3)),
      );

      final s = (await suggest()).single;
      expect(s.kind, PairingKind.transfer);
      expect(s.from.id, out);
      expect(s.to.id, inc);
      expect(s.from.label, 'MTB');
      expect(s.gap, const Duration(hours: 2));
      expect(s.amountDifference.toString(), '10');
      expect(s.otherMatches, 0);
    });

    test('legs carry their SMS sender and text', () async {
      final outMsg = await insertSms(
        db,
        sender: 'MTB',
        content: 'debit 1500',
        ts: 1,
      );
      final out = await insertTx(
        db,
        messageId: outMsg,
        bankId: mtb,
        amount: '1500',
        type: 'expense',
        date: ago(const Duration(hours: 5)),
      );
      final inc = await insertTx(
        db,
        messageId: 9999,
        bankId: city,
        amount: '1500',
        type: 'income',
        date: ago(const Duration(hours: 3)),
      );

      final s = (await suggest()).single;
      expect(s.from.id, out);
      expect(s.from.message?.sender, 'MTB');
      expect(s.from.message?.content, 'debit 1500');
      // No SMS row behind this leg's message id.
      expect(s.to.id, inc);
      expect(s.to.message, isNull);
    });

    test('never pairs two rows on the same account', () async {
      await tx(mtb, 'expense', '1500', ago(const Duration(hours: 5)));
      await tx(mtb, 'income', '1500', ago(const Duration(hours: 4)));
      expect(await suggest(), isEmpty);
    });

    test('honors the ±10.00 amount tolerance', () async {
      await tx(mtb, 'expense', '1510.01', ago(const Duration(hours: 5)));
      await tx(city, 'income', '1500', ago(const Duration(hours: 4)));
      expect(await suggest(), isEmpty);
    });

    test('honors the 96h window, inclusive', () async {
      final t = ago(const Duration(days: 10));
      await tx(mtb, 'expense', '1500', t);
      await tx(city, 'income', '1500', t.add(const Duration(hours: 96)));
      await tx(dbbl, 'expense', '700', t);
      await tx(
        city,
        'income',
        '700',
        t.add(const Duration(hours: 96, minutes: 1)),
      );

      final all = await suggest();
      expect(all.single.from.amount, '1500');
    });

    test('suggests a transfer when income is 96h before expense', () async {
      final t = ago(const Duration(days: 5));
      await tx(city, 'income', '1500', t);
      final out = await tx(
        mtb,
        'expense',
        '1500',
        t.add(const Duration(hours: 96)),
      );

      final s = (await suggest()).single;
      expect(s.kind, PairingKind.transfer);
      expect(s.from.id, out);
      expect(s.gap, const Duration(hours: 96));
    });

    test('skips credit accounts, other currencies and paired rows', () async {
      final t = ago(const Duration(hours: 10));
      // An income on a credit card is not a deposit-to-deposit transfer.
      await tx(mtb, 'expense', '100', t);
      await tx(ebl, 'income', '100', t);
      // Different currencies.
      await tx(mtb, 'expense', '200', t);
      await tx(city, 'income', '200', t, currency: 'USD');
      // Already paired.
      await tx(mtb, 'expense', '300', t, pairedWithId: 999);
      await tx(city, 'income', '300', t);

      expect(await suggest(), isEmpty);
    });
  });

  group('card-payment candidates', () {
    test('pairs a bank debit with a card payment days apart', () async {
      final out = await tx(
        mtb,
        'expense',
        '2951',
        ago(const Duration(days: 3)),
      );
      final card = await tx(
        ebl,
        'transfer',
        '2950.50',
        ago(const Duration(days: 2)),
      );

      final s = (await suggest()).single;
      expect(s.kind, PairingKind.cardPayment);
      expect(s.from.id, out);
      expect(s.to.id, card);
      expect(s.to.label, 'EBL ••1234');
    });

    test('honors the ±1.00 amount tolerance', () async {
      await tx(mtb, 'expense', '2952.01', ago(const Duration(days: 3)));
      await tx(ebl, 'transfer', '2951', ago(const Duration(days: 2)));
      expect(await suggest(), isEmpty);
    });

    test(
      'suggests a card payment when the card transfer is before the expense',
      () async {
        final t = ago(const Duration(days: 5));
        await tx(ebl, 'transfer', '2950', t);
        final out = await tx(
          mtb,
          'expense',
          '2951',
          t.add(const Duration(hours: 10)),
        );

        final s = (await suggest()).single;
        expect(s.kind, PairingKind.cardPayment);
        expect(s.from.id, out);
      },
    );

    test('ignores an expense on a credit account as the bank leg', () async {
      final other = await insertBank(
        db,
        name: 'BRAC',
        accountType: 'credit',
        cardDigits: '1111|2222',
      );
      await tx(other, 'expense', '2951', ago(const Duration(days: 3)));
      await tx(ebl, 'transfer', '2951', ago(const Duration(days: 2)));
      expect(await suggest(), isEmpty);
    });

    test('a tie inside 15 min stays unpaired and becomes one card', () async {
      final t = ago(const Duration(hours: 1));
      await tx(ebl, 'transfer', '5000', t);
      await tx(mtb, 'expense', '5000', t.subtract(const Duration(minutes: 5)));
      await tx(city, 'expense', '5000', t.add(const Duration(minutes: 5)));

      await FinanceMatcher(
        db,
        nowMs: () => now.millisecondsSinceEpoch,
      ).runPending();
      final paired = await db.query(
        'transactions',
        where: 'paired_with_id IS NOT NULL',
      );
      expect(paired, isEmpty);

      final s = (await suggest()).single;
      expect(s.kind, PairingKind.cardPayment);
      expect(s.otherMatches, 1);
    });
  });

  group('global matching', () {
    test('takes the smallest gaps first across the whole pool', () async {
      // All 1500. X MTB out 10:00, Y MTB out 12:00, A City in 10:50,
      // B DBBL in 10:10 -> B–X (10m) then A–Y (70m).
      final day = ago(const Duration(days: 2));
      DateTime at(int h, int m) => DateTime(day.year, day.month, day.day, h, m);
      final x = await tx(mtb, 'expense', '1500', at(10, 0));
      final y = await tx(mtb, 'expense', '1500', at(12, 0));
      final a = await tx(city, 'income', '1500', at(10, 50));
      final b = await tx(dbbl, 'income', '1500', at(10, 10));

      final all = await suggest();
      final pairs = {for (final s in all) s.to.id: s.from.id};
      expect(pairs, {b: x, a: y});
      expect(all[0].otherMatches, 2);
      expect(all[1].otherMatches, 2);
    });

    test('a debit shared by both kinds goes to the closer partner', () async {
      final t = ago(const Duration(days: 1));
      final out = await tx(mtb, 'expense', '2000', t);
      final card = await tx(
        ebl,
        'transfer',
        '2000',
        t.add(const Duration(hours: 1)),
      );
      await tx(city, 'income', '2000', t.add(const Duration(hours: 5)));

      final s = (await suggest()).single;
      expect(s.from.id, out);
      expect(s.to.id, card);
      expect(s.otherMatches, 1);
    });

    test('each transaction appears in at most one suggestion', () async {
      final t = ago(const Duration(days: 1));
      await tx(city, 'income', '1500', t);
      await tx(mtb, 'expense', '1500', t.subtract(const Duration(hours: 1)));
      await tx(mtb, 'expense', '1500', t.subtract(const Duration(hours: 2)));

      final s = (await suggest()).single;
      expect(s.gap, const Duration(hours: 1));
      expect(s.otherMatches, 1);
    });
  });

  group('rejections and window', () {
    test('a rejected pair is skipped and the next best surfaces', () async {
      final t = ago(const Duration(days: 1));
      final inc = await tx(city, 'income', '1500', t);
      final near = await tx(
        mtb,
        'expense',
        '1500',
        t.subtract(const Duration(hours: 1)),
      );
      final far = await tx(
        mtb,
        'expense',
        '1500',
        t.subtract(const Duration(hours: 2)),
      );
      await db.insert('pairing_rejections', {
        'tx_low': near < inc ? near : inc,
        'tx_high': near < inc ? inc : near,
        'expires_at': now.add(const Duration(days: 30)).millisecondsSinceEpoch,
      });

      final s = (await suggest()).single;
      expect(s.from.id, far);
      expect(s.otherMatches, 0);
    });

    test('the newer leg must be within the last 30 days', () async {
      await tx(mtb, 'expense', '1500', ago(const Duration(days: 33)));
      await tx(city, 'income', '1500', ago(const Duration(days: 31)));
      expect(await suggest(), isEmpty);

      // The older leg may sit before the floor while the newer one is inside.
      await tx(dbbl, 'expense', '800', ago(const Duration(days: 32)));
      await tx(city, 'income', '800', ago(const Duration(days: 29)));
      expect((await suggest()).single.from.amount, '800');
    });

    test('orders suggestions newest first', () async {
      await tx(mtb, 'expense', '100', ago(const Duration(days: 5)));
      await tx(city, 'income', '100', ago(const Duration(days: 5)));
      await tx(mtb, 'expense', '200', ago(const Duration(days: 1)));
      await tx(city, 'income', '200', ago(const Duration(days: 1)));

      final amounts = [for (final s in await suggest()) s.from.amount];
      expect(amounts, ['200', '100']);
    });

    test(
      'a rejection row with reversed tx_low/tx_high still excludes the pair',
      () async {
        final t = ago(const Duration(days: 1));
        final out = await tx(mtb, 'expense', '1500', t);
        final inc = await tx(city, 'income', '1500', t);
        // Insert the rejection with tx_low and tx_high reversed.
        await db.insert('pairing_rejections', {
          'tx_low': out > inc ? out : inc,
          'tx_high': out > inc ? inc : out,
          'expires_at': now
              .add(const Duration(days: 30))
              .millisecondsSinceEpoch,
        });

        expect(await suggest(), isEmpty);
      },
    );
  });
}
