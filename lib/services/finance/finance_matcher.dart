import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../../data/database.dart';

/// Deferred matching of credit-card money movements, ported from the server's
/// transfer_matcher + bill_payment_matcher. Runs opportunistically after each
/// processing pass (and on resume) over recently-created unmatched rows, rather
/// than on 10-minute daemon threads.
///
/// - Transfer pairing: a credit-card "transfer" (bill-payment received by the
///   issuer) is paired with the bank debit that funded it (±1.00 amount,
///   ±15 min, closest wins, ambiguity skipped).
/// - Bill-payment linking: a credit-card transfer is linked to the matching
///   Bill on that card (±1.00, ±45 days, bill-before-payment preferred),
///   populating bill_id on both paired transactions + paid_at on the bill.
class FinanceMatcher {
  FinanceMatcher(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Database _db;
  final int Function() _nowMs;

  static final Decimal tolerance = Decimal.parse('1.00');
  static const Duration transferWindow = Duration(minutes: 15);
  static const Duration billWindow = Duration(days: 45);

  /// Scans recent unmatched rows and applies both matchers. Each match runs in
  /// its own DB transaction so the two/three row updates commit together (no
  /// half-written pair or one-sided bill link if the process dies mid-pass).
  ///
  /// The look-back is bounded to the bill window (45 days): a transfer older
  /// than that can no longer pair (its ±15 min counterpart would long since have
  /// been processed), and this generous bound still lets a late-arriving
  /// counterpart pair with a transfer created up to 45 days earlier.
  Future<void> runPending() async {
    final cutoff = _nowMs() - billWindow.inMilliseconds;

    for (final id in await _ids(
      "type = 'transfer' AND paired_with_id IS NULL AND date >= ?",
      [cutoff],
    )) {
      await _db.transaction((txn) => findAndPairTransferCounterpart(txn, id));
    }
    for (final id in await _ids(
      "type = 'transfer' AND bill_id IS NULL AND bank_id IS NOT NULL AND date >= ?",
      [cutoff],
    )) {
      await _db.transaction((txn) => findAndLinkBillForPayment(txn, id));
    }
    for (final billId in await _billIds(cutoff)) {
      await _db.transaction((txn) => findAndLinkPaymentForBill(txn, billId));
    }
  }

  Future<List<int>> _ids(String where, List<Object?> args) async {
    final rows = await _db.query(
      AppDatabase.transactionsTable,
      columns: ['id'],
      where: where,
      whereArgs: args,
    );
    return rows.map((r) => r['id'] as int).toList();
  }

  Future<List<int>> _billIds(int cutoff) async {
    final rows = await _db.rawQuery(
      'SELECT b.id AS id FROM ${AppDatabase.billsTable} b '
      'JOIN ${AppDatabase.smsTable} s ON s.id = b.message_id '
      'WHERE b.paid_at IS NULL AND s.timestamp >= ?',
      [cutoff],
    );
    return rows.map((r) => r['id'] as int).toList();
  }
}

// ---- pure matchers (top-level so they are directly unit-testable) ----------

/// Pairs [transferTxId] with its funding bank debit. Returns the paired
/// counterpart id, or null when there is no unique match.
Future<int?> findAndPairTransferCounterpart(
  DatabaseExecutor db,
  int transferTxId,
) async {
  final tx = await _loadTx(db, transferTxId);
  if (tx == null || tx.type != 'transfer' || tx.pairedWithId != null) {
    return null;
  }
  final amount = Decimal.parse(tx.amount);
  final start = tx.date - FinanceMatcher.transferWindow.inMilliseconds;
  final end = tx.date + FinanceMatcher.transferWindow.inMilliseconds;

  final rows = await db.query(
    AppDatabase.transactionsTable,
    where:
        "type = 'expense' AND paired_with_id IS NULL AND id != ? "
        'AND date >= ? AND date <= ?',
    whereArgs: [tx.id, start, end],
  );
  final candidates = rows
      .where((r) => _within(r['normalized_amount'] as String, amount))
      .toList();
  if (candidates.isEmpty) return null;

  int delta(Map<String, Object?> r) => ((r['date'] as int) - tx.date).abs();
  candidates.sort((a, b) => delta(a).compareTo(delta(b)));
  final closest = delta(candidates.first);
  final tied = candidates.where((r) => delta(r) == closest).toList();
  if (tied.length > 1) return null; // ambiguous — leave for manual reconcile

  final winnerId = tied.first['id'] as int;
  await db.update(
    AppDatabase.transactionsTable,
    {'type': 'transfer', 'paired_with_id': tx.id},
    where: 'id = ?',
    whereArgs: [winnerId],
  );
  await db.update(
    AppDatabase.transactionsTable,
    {'paired_with_id': winnerId},
    where: 'id = ?',
    whereArgs: [tx.id],
  );
  return winnerId;
}

/// Links a credit-card transfer [transferTxId] to the matching Bill on that
/// card. Returns the linked bill id, or null.
Future<int?> findAndLinkBillForPayment(
  DatabaseExecutor db,
  int transferTxId,
) async {
  final tx = await _loadTx(db, transferTxId);
  if (tx == null ||
      tx.type != 'transfer' ||
      tx.billId != null ||
      tx.bankId == null) {
    return null;
  }
  final bank = await _bankIsCredit(db, tx.bankId!);
  if (!bank) return null;

  final amount = Decimal.parse(tx.amount);
  final start = tx.date - FinanceMatcher.billWindow.inMilliseconds;
  final end = tx.date + FinanceMatcher.billWindow.inMilliseconds;

  final rows = await db.rawQuery(
    'SELECT b.id AS id, b.normalized_total_due AS total, '
    's.timestamp AS received_at FROM ${AppDatabase.billsTable} b '
    'JOIN ${AppDatabase.smsTable} s ON s.id = b.message_id '
    'WHERE b.bank_id = ? AND b.normalized_currency = ? '
    'AND s.timestamp >= ? AND s.timestamp <= ?',
    [tx.bankId, tx.currency, start, end],
  );

  final candidates = <Map<String, Object?>>[];
  for (final r in rows) {
    if (!_within(r['total'] as String, amount)) continue;
    final linked = await db.query(
      AppDatabase.transactionsTable,
      columns: ['id'],
      where: 'bill_id = ?',
      whereArgs: [r['id']],
      limit: 1,
    );
    if (linked.isEmpty) candidates.add(r);
  }
  if (candidates.isEmpty) return null;

  // Prefer a bill received before the payment, then closest in time.
  int diff(Map<String, Object?> r) => tx.date - (r['received_at'] as int);
  bool billBefore(Map<String, Object?> r) => diff(r) >= 0;
  candidates.sort((a, b) {
    if (billBefore(a) != billBefore(b)) return billBefore(a) ? -1 : 1;
    return diff(a).abs().compareTo(diff(b).abs());
  });
  final top = candidates.first;
  final tied = candidates
      .where((r) =>
          billBefore(r) == billBefore(top) && diff(r).abs() == diff(top).abs())
      .toList();
  if (tied.length > 1) return null;

  await _link(db, billId: top['id'] as int, tx: tx);
  return top['id'] as int;
}

/// Links Bill [billId] to the transfer that paid it. Returns the payment tx id.
Future<int?> findAndLinkPaymentForBill(DatabaseExecutor db, int billId) async {
  final bill = await _loadBill(db, billId);
  if (bill == null || bill.bankId == null) return null;

  final total = Decimal.parse(bill.total);
  final start = bill.receivedAt - FinanceMatcher.billWindow.inMilliseconds;
  final end = bill.receivedAt + FinanceMatcher.billWindow.inMilliseconds;

  final rows = await db.query(
    AppDatabase.transactionsTable,
    where:
        "type = 'transfer' AND bank_id = ? AND bill_id IS NULL "
        'AND normalized_currency = ? AND date >= ? AND date <= ?',
    whereArgs: [bill.bankId, bill.currency, start, end],
  );
  final candidates = rows
      .where((r) => _within(r['normalized_amount'] as String, total))
      .toList();
  if (candidates.isEmpty) return null;

  // Prefer a payment at/after the bill, then closest in time.
  int diff(Map<String, Object?> r) => (r['date'] as int) - bill.receivedAt;
  bool paymentBefore(Map<String, Object?> r) => diff(r) < 0;
  candidates.sort((a, b) {
    if (paymentBefore(a) != paymentBefore(b)) return paymentBefore(a) ? 1 : -1;
    return diff(a).abs().compareTo(diff(b).abs());
  });
  final top = candidates.first;
  final tied = candidates
      .where((r) =>
          paymentBefore(r) == paymentBefore(top) &&
          diff(r).abs() == diff(top).abs())
      .toList();
  if (tied.length > 1) return null;

  // `top` comes from a default-column query, so it carries paired_with_id — kept
  // that way so _link can propagate bill_id to the paired counterpart.
  await _link(db, billId: bill.id, tx: _Tx.fromRow(top));
  return top['id'] as int;
}

// ---- helpers ---------------------------------------------------------------

bool _within(String value, Decimal target) =>
    (Decimal.parse(value) - target).abs() <= FinanceMatcher.tolerance;

Future<void> _link(
  DatabaseExecutor db, {
  required int billId,
  required _Tx tx,
}) async {
  await db.update(
    AppDatabase.transactionsTable,
    {'bill_id': billId},
    where: 'id = ?',
    whereArgs: [tx.id],
  );
  if (tx.pairedWithId != null) {
    await db.update(
      AppDatabase.transactionsTable,
      {'bill_id': billId},
      where: 'id = ?',
      whereArgs: [tx.pairedWithId],
    );
  }
  await db.update(
    AppDatabase.billsTable,
    {'paid_at': tx.date},
    where: 'id = ?',
    whereArgs: [billId],
  );
}

Future<bool> _bankIsCredit(DatabaseExecutor db, int bankId) async {
  final rows = await db.query(
    AppDatabase.banksTable,
    columns: ['account_type'],
    where: 'id = ?',
    whereArgs: [bankId],
    limit: 1,
  );
  return rows.isNotEmpty && rows.first['account_type'] == 'credit';
}

class _Tx {
  _Tx({
    required this.id,
    required this.bankId,
    required this.pairedWithId,
    required this.billId,
    required this.amount,
    required this.currency,
    required this.type,
    required this.date,
  });

  factory _Tx.fromRow(Map<String, Object?> r) => _Tx(
    id: r['id'] as int,
    bankId: r['bank_id'] as int?,
    pairedWithId: r['paired_with_id'] as int?,
    billId: r['bill_id'] as int?,
    amount: r['normalized_amount'] as String,
    currency: r['normalized_currency'] as String,
    type: r['type'] as String,
    date: r['date'] as int,
  );

  final int id;
  final int? bankId;
  final int? pairedWithId;
  final int? billId;
  final String amount;
  final String currency;
  final String type;
  final int date;
}

Future<_Tx?> _loadTx(DatabaseExecutor db, int id) async {
  final rows = await db.query(
    AppDatabase.transactionsTable,
    where: 'id = ?',
    whereArgs: [id],
    limit: 1,
  );
  return rows.isEmpty ? null : _Tx.fromRow(rows.first);
}

class _Bill {
  _Bill({
    required this.id,
    required this.bankId,
    required this.total,
    required this.currency,
    required this.receivedAt,
  });

  final int id;
  final int? bankId;
  final String total;
  final String currency;
  final int receivedAt;
}

Future<_Bill?> _loadBill(DatabaseExecutor db, int id) async {
  final rows = await db.rawQuery(
    'SELECT b.id AS id, b.bank_id AS bank_id, '
    'b.normalized_total_due AS total, b.normalized_currency AS currency, '
    's.timestamp AS received_at FROM ${AppDatabase.billsTable} b '
    'JOIN ${AppDatabase.smsTable} s ON s.id = b.message_id WHERE b.id = ?',
    [id],
  );
  if (rows.isEmpty) return null;
  final r = rows.first;
  return _Bill(
    id: r['id'] as int,
    bankId: r['bank_id'] as int?,
    total: r['total'] as String,
    currency: r['currency'] as String,
    receivedAt: r['received_at'] as int,
  );
}
