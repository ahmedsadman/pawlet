import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/database.dart';
import '../../models/finance/pairing_suggestion.dart';
import '../../models/finance/transaction.dart';
import 'finance_matcher.dart';

/// Finds transaction pairs worth asking the user about: money moved between
/// two deposit accounts, and bank debits that paid a card but fell outside the
/// automatic 15-minute pairing (or tied inside it).
///
/// Computed fresh on every read so a deleted, retyped or auto-paired row can
/// never leave a stale card behind; only the user's "No" answers are stored.
///
/// Every candidate goes into one pool, sorted by time gap, then amount
/// difference, then id, and pairs are taken greedily so each transaction is in
/// at most one suggestion.
class PairingSuggester {
  PairingSuggester(this._db);

  final DatabaseExecutor _db;

  /// The furthest apart two legs may be dated.
  static const Duration window = Duration(hours: 96);

  /// The newer leg of a suggested pair is at most this old.
  static const Duration lookBack = Duration(days: 30);

  static final Decimal transferTolerance = Decimal.parse('10.00');

  /// Card payments use the automatic matcher's tolerance.
  static Decimal get cardTolerance => FinanceMatcher.tolerance;

  /// The suggestions as of [nowMs], newest first.
  Future<List<PairingSuggestion>> suggest({required int nowMs}) async {
    final floor = nowMs - lookBack.inMilliseconds;
    final rows = await _db.rawQuery(
      '''
      SELECT t.id, t.message_id, t.bank_id, t.normalized_amount,
             t.normalized_currency, t.type, t.date,
             b.name AS bank_name, b.account_type, b.card_digits
      FROM ${AppDatabase.transactionsTable} t
      JOIN ${AppDatabase.banksTable} b ON b.id = t.bank_id
      WHERE t.paired_with_id IS NULL AND t.date >= ?
        AND ((b.account_type = 'deposit' AND t.type IN ('income', 'expense'))
          OR (b.account_type = 'credit' AND t.type = 'transfer'))
      ''',
      // The older leg may sit up to one window before the floor.
      [floor - window.inMilliseconds],
    );
    final legs = rows.map(_legFromRow).toList();
    final outs = [
      for (final l in legs)
        if (!l.isCredit && l.type == TxType.expense) l,
    ];
    final ins = [
      for (final l in legs)
        if (!l.isCredit && l.type == TxType.income) l,
    ];
    final cards = [
      for (final l in legs)
        if (l.isCredit) l,
    ];
    final rejected = await _rejectedKeys();

    final pool = <PairingSuggestion>[];
    void consider(
      PairingKind kind,
      PairingLeg from,
      PairingLeg to,
      Decimal tolerance,
    ) {
      if (from.currency != to.currency) return;
      final s = PairingSuggestion(kind: kind, from: from, to: to);
      if (s.gap > window) return;
      if (s.amountDifference > tolerance) return;
      if (s.newerDate.millisecondsSinceEpoch < floor) return;
      if (rejected.contains(s.key)) return;
      pool.add(s);
    }

    for (final from in outs) {
      for (final to in ins) {
        if (from.bankId != to.bankId) {
          consider(PairingKind.transfer, from, to, transferTolerance);
        }
      }
      for (final to in cards) {
        consider(PairingKind.cardPayment, from, to, cardTolerance);
      }
    }

    pool.sort(_byStrength);
    final used = <int>{};
    final taken = <PairingSuggestion>[];
    for (final s in pool) {
      if (used.contains(s.from.id) || used.contains(s.to.id)) continue;
      used
        ..add(s.from.id)
        ..add(s.to.id);
      taken.add(s);
    }

    final result = [
      for (final s in taken)
        PairingSuggestion(
          kind: s.kind,
          from: s.from,
          to: s.to,
          otherMatches: pool
              .where((o) => !identical(o, s) && _sharesLeg(o, s))
              .length,
        ),
    ];
    result.sort((a, b) {
      final byDate = b.newerDate.compareTo(a.newerDate);
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });
    return result;
  }

  Future<Set<String>> _rejectedKeys() async {
    final rows = await _db.query(
      AppDatabase.pairingRejectionsTable,
      columns: ['tx_low', 'tx_high'],
    );
    return {for (final r in rows) '${r['tx_low']}-${r['tx_high']}'};
  }

  static int _byStrength(PairingSuggestion a, PairingSuggestion b) {
    final byGap = a.gap.compareTo(b.gap);
    if (byGap != 0) return byGap;
    final byAmount = a.amountDifference.compareTo(b.amountDifference);
    if (byAmount != 0) return byAmount;
    final byLow = a.lowId.compareTo(b.lowId);
    return byLow != 0 ? byLow : a.highId.compareTo(b.highId);
  }

  static bool _sharesLeg(PairingSuggestion a, PairingSuggestion b) =>
      a.from.id == b.from.id ||
      a.from.id == b.to.id ||
      a.to.id == b.from.id ||
      a.to.id == b.to.id;

  static PairingLeg _legFromRow(Map<String, Object?> r) => PairingLeg(
    id: r['id'] as int,
    messageId: r['message_id'] as int?,
    bankId: r['bank_id'] as int,
    bankName: r['bank_name'] as String,
    accountType: r['account_type'] as String,
    cardDigits: r['card_digits'] as String?,
    amount: r['normalized_amount'] as String,
    currency: r['normalized_currency'] as String,
    type: TxType.fromValue(r['type'] as String),
    date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int),
  );
}
