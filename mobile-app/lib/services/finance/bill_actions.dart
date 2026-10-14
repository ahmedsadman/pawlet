import 'package:sqflite/sqflite.dart';

import '../../data/database.dart';

/// Applies the user's paid/unpaid answer for a credit-card bill.
///
/// Either answer sets `status_overridden`, which takes the bill out of
/// `FinanceMatcher` for good, so a background pass cannot undo it.
class BillActions {
  BillActions(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Database _db;
  final int Function() _nowMs;

  /// Marks [billId] paid (stamped now unless it already has a paid date;
  /// existing payment links are kept) or unpaid (every linked payment leg is
  /// unlinked).
  Future<void> setPaid(int billId, {required bool paid}) =>
      _db.transaction((txn) async {
        if (paid) {
          await txn.rawUpdate(
            'UPDATE ${AppDatabase.billsTable} '
            'SET paid_at = COALESCE(paid_at, ?), status_overridden = 1 '
            'WHERE id = ?',
            [_nowMs(), billId],
          );
          return;
        }
        await txn.update(
          AppDatabase.transactionsTable,
          {'bill_id': null},
          where: 'bill_id = ?',
          whereArgs: [billId],
        );
        await txn.update(
          AppDatabase.billsTable,
          {'paid_at': null, 'status_overridden': 1},
          where: 'id = ?',
          whereArgs: [billId],
        );
      });
}
