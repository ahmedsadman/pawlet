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

  /// The bill an accepted card payment linked, so undo touches only that link.
  final int? linkedBillId;
}

/// Applies the user's pairing-review answers.
class PairingActions {
  PairingActions(this._db);

  final Database _db;

  /// Pairs the two legs: both become `transfer` rows pointing at each other,
  /// and an accepted card payment is linked to its bill straight away.
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
        final billId = s.kind == PairingKind.cardPayment
            ? await findAndLinkBillForPayment(txn, s.to.id)
            : null;
        return PairingDecision(s, accepted: true, linkedBillId: billId);
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
  /// still point at each other.
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
      final rows = await txn.query(
        AppDatabase.transactionsTable,
        columns: ['paired_with_id'],
        where: 'id = ?',
        whereArgs: [s.from.id],
      );
      if (rows.isEmpty || rows.first['paired_with_id'] != s.to.id) return;

      final billId = d.linkedBillId;
      await txn.update(
        AppDatabase.transactionsTable,
        {
          'type': 'expense',
          'paired_with_id': null,
          if (billId != null) 'bill_id': null,
        },
        where: 'id = ?',
        whereArgs: [s.from.id],
      );
      await txn.update(
        AppDatabase.transactionsTable,
        {
          if (s.kind == PairingKind.transfer) 'type': 'income',
          'paired_with_id': null,
          if (billId != null) 'bill_id': null,
        },
        where: 'id = ?',
        whereArgs: [s.to.id],
      );
      if (billId != null) {
        await txn.update(
          AppDatabase.billsTable,
          {'paid_at': null},
          where: 'id = ?',
          whereArgs: [billId],
        );
      }
    });
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
