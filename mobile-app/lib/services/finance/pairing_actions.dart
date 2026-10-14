import 'package:sqflite/sqflite.dart';

import '../../data/database.dart';
import '../../models/finance/pairing_suggestion.dart';
import 'finance_matcher.dart';
import 'pairing_suggester.dart';

/// The outcome of one review answer, kept so the Undo snackbar can reverse it.
class PairingDecision {
  const PairingDecision(
    this.suggestion, {
    required this.accepted,
    this.linkedBillId,
  });

  final PairingSuggestion suggestion;
  final bool accepted;

  /// The bill this accept linked to the card payment, so undo clears only a
  /// link it made. Null when the card leg was already bill-linked beforehand
  /// (its bill was only copied onto the bank leg) or no bill matched.
  final int? linkedBillId;
}

/// Applies the user's pairing-review answers.
class PairingActions {
  PairingActions(this._db);

  final Database _db;

  /// Pairs the two legs: both become `transfer` rows pointing at each other.
  /// For a card payment, the bank leg takes the card leg's bill if it already
  /// has one; otherwise the card payment is linked to its bill straight away,
  /// which gives both legs the bill.
  ///
  /// Returns null, writing nothing, when either leg changed since the
  /// suggestion was built (e.g. a background pass auto-paired it).
  Future<PairingDecision?> accept(PairingSuggestion s) =>
      _db.transaction((txn) async {
        final toType = s.kind == PairingKind.transfer ? 'income' : 'transfer';
        if (!await _isUnpaired(txn, s.from.id, 'expense') ||
            !await _isUnpaired(txn, s.to.id, toType)) {
          return null;
        }
        await txn.update(
          AppDatabase.transactionsTable,
          {'type': 'transfer', 'paired_with_id': s.to.id},
          where: 'id = ?',
          whereArgs: [s.from.id],
        );
        await txn.update(
          AppDatabase.transactionsTable,
          {
            if (s.kind == PairingKind.transfer) 'type': 'transfer',
            'paired_with_id': s.from.id,
          },
          where: 'id = ?',
          whereArgs: [s.to.id],
        );
        int? linkedBillId;
        if (s.kind == PairingKind.cardPayment) {
          final existing = await _billId(txn, s.to.id);
          if (existing != null) {
            await txn.update(
              AppDatabase.transactionsTable,
              {'bill_id': existing},
              where: 'id = ?',
              whereArgs: [s.from.id],
            );
          } else {
            linkedBillId = await findAndLinkBillForPayment(txn, s.to.id);
          }
        }
        return PairingDecision(s, accepted: true, linkedBillId: linkedBillId);
      });

  /// Records that the two legs are not a pair. The rejection expires when the
  /// pair leaves the review window.
  Future<PairingDecision> reject(PairingSuggestion s) async {
    await _db.insert(
      AppDatabase.pairingRejectionsTable,
      {
        'tx_low': s.lowId,
        'tx_high': s.highId,
        'expires_at': s.newerDate
            .add(PairingSuggester.lookBack)
            .millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    return PairingDecision(s, accepted: false);
  }

  /// Reverses [d]. An accepted pairing is only reversed while the two legs
  /// still point at each other. Undoing a card payment always clears the bank
  /// leg's bill; the card leg's bill is cleared only when this accept made that
  /// link ([PairingDecision.linkedBillId]), and then the bill's `paid_at` is
  /// cleared too unless the user overrode the bill's status.
  Future<void> undo(PairingDecision d) async {
    final s = d.suggestion;
    if (!d.accepted) {
      await _db.delete(
        AppDatabase.pairingRejectionsTable,
        where: 'tx_low = ? AND tx_high = ?',
        whereArgs: [s.lowId, s.highId],
      );
      return;
    }
    await _db.transaction((txn) async {
      if (await _pairedWith(txn, s.from.id) != s.to.id ||
          await _pairedWith(txn, s.to.id) != s.from.id) {
        return;
      }

      final isCard = s.kind == PairingKind.cardPayment;
      await txn.update(
        AppDatabase.transactionsTable,
        {
          'type': 'expense',
          'paired_with_id': null,
          if (isCard) 'bill_id': null,
        },
        where: 'id = ?',
        whereArgs: [s.from.id],
      );
      await txn.update(
        AppDatabase.transactionsTable,
        {if (!isCard) 'type': 'income', 'paired_with_id': null},
        where: 'id = ?',
        whereArgs: [s.to.id],
      );
      final billId = d.linkedBillId;
      if (billId == null) return;
      final unlinked = await txn.update(
        AppDatabase.transactionsTable,
        {'bill_id': null},
        where: 'id = ? AND bill_id = ?',
        whereArgs: [s.to.id, billId],
      );
      if (unlinked > 0) {
        await txn.update(
          AppDatabase.billsTable,
          {'paid_at': null},
          where: 'id = ? AND status_overridden = 0',
          whereArgs: [billId],
        );
      }
    });
  }

  Future<int?> _pairedWith(DatabaseExecutor db, int id) =>
      _column(db, id, 'paired_with_id');

  Future<int?> _billId(DatabaseExecutor db, int id) =>
      _column(db, id, 'bill_id');

  Future<int?> _column(DatabaseExecutor db, int id, String column) async {
    final rows = await db.query(
      AppDatabase.transactionsTable,
      columns: [column],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first[column] as int?;
  }

  Future<bool> _isUnpaired(DatabaseExecutor db, int id, String type) async {
    final rows = await db.query(
      AppDatabase.transactionsTable,
      columns: ['id'],
      where: 'id = ? AND type = ? AND paired_with_id IS NULL',
      whereArgs: [id, type],
      limit: 1,
    );
    return rows.isNotEmpty;
  }
}
