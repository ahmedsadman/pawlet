import 'package:sqflite/sqflite.dart';

import '../../data/database.dart';
import '../../models/finance/bank.dart';
import '../../models/sms_record.dart';
import '../classification/classifier.dart';
import '../classification/sender_matcher.dart';
import '../llm/llm_provider.dart';

/// Persists the outcome of a classified SMS into the local finance tables,
/// porting the server's record logic (dedupe, bank matching, deposit balance
/// updates, strict credit-card bills). Returns the category label to store on
/// the SMS row: `transaction` | `bill` | `ignored`.
class FinanceWriter {
  FinanceWriter(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Database _db;
  final int Function() _nowMs;

  /// Applies the outcome in a single DB transaction so the balance update and
  /// the row insert commit together (or not at all).
  Future<String> apply({
    required SmsRecord record,
    required ClassificationOutcome outcome,
    required List<Bank> banks,
    required String currency,
  }) {
    return _db.transaction<String>(
      (txn) => _apply(txn, record, outcome, banks, currency),
    );
  }

  Future<String> _apply(
    DatabaseExecutor db,
    SmsRecord record,
    ClassificationOutcome outcome,
    List<Bank> banks,
    String currency,
  ) async {
    switch (outcome.category) {
      case SmsCategory.transaction:
        final wrote = await _recordTransaction(
          db,
          record,
          outcome.transaction ?? const MetadataResult(),
          banks,
          currency,
        );
        return wrote ? 'transaction' : 'ignored';
      case SmsCategory.bill:
        final wrote = await _recordBill(
          db,
          record,
          outcome.bill ?? const BillMetadataResult(),
          banks,
          currency,
        );
        return wrote ? 'bill' : 'ignored';
      case SmsCategory.none:
        return 'ignored';
    }
  }

  // ---- transactions -------------------------------------------------------

  Future<bool> _recordTransaction(
    DatabaseExecutor db,
    SmsRecord record,
    MetadataResult meta,
    List<Bank> banks,
    String currency,
  ) async {
    if (meta.amount == null || meta.transactionType == null) return false;
    if (await _exists(db, AppDatabase.transactionsTable, record.id!)) {
      return false;
    }

    // Bank match: credit-card digits in content first, else the LLM's name.
    final bank =
        matchCreditCardInContent(record.content, banks) ??
        _matchByName(banks, meta.bank);

    await _maybeUpdateBalance(db, bank, meta, record, currency);

    await db.insert(AppDatabase.transactionsTable, {
      'message_id': record.id,
      'bank_id': bank?.id,
      'normalized_amount': meta.amount,
      'normalized_currency': currency,
      'original_amount': meta.originalAmount,
      'original_currency': meta.originalCurrency,
      'type': meta.transactionType,
      'date': record.timestamp,
      'created_at': _nowMs(),
    });
    return true;
  }

  Future<void> _maybeUpdateBalance(
    DatabaseExecutor db,
    Bank? bank,
    MetadataResult meta,
    SmsRecord record,
    String currency,
  ) async {
    if (bank == null || meta.balance == null || bank.isCredit) return;
    // Don't trust a balance that was in a different source currency.
    if (meta.originalCurrency != null && meta.originalCurrency != currency) {
      return;
    }
    final lastAt = bank.lastBalanceAt?.millisecondsSinceEpoch;
    if (lastAt != null && record.timestamp <= lastAt) return;

    await db.update(
      AppDatabase.banksTable,
      {'last_balance': meta.balance, 'last_balance_at': record.timestamp},
      where: 'id = ?',
      whereArgs: [bank.id],
    );
  }

  // ---- bills (strict: require a matching credit card) ---------------------

  Future<bool> _recordBill(
    DatabaseExecutor db,
    SmsRecord record,
    BillMetadataResult meta,
    List<Bank> banks,
    String currency,
  ) async {
    if (meta.normalizedTotalDue == null) return false;

    // Strict: the bill's card must appear in the content; that credit bank is
    // authoritative (the LLM's bank guess is not enough on its own).
    final bank = matchCreditCardInContent(record.content, banks);
    if (bank == null) return false;

    if (await _exists(db, AppDatabase.billsTable, record.id!)) return true;

    int? statementPeriod;
    if (meta.statementMonth != null && meta.statementYear != null) {
      statementPeriod = DateTime(
        meta.statementYear!,
        meta.statementMonth!,
        1,
      ).millisecondsSinceEpoch;
      // De-duplicate a re-sent statement for the same card + period.
      final dupe = await db.query(
        AppDatabase.billsTable,
        where: 'bank_id = ? AND statement_period = ?',
        whereArgs: [bank.id, statementPeriod],
        limit: 1,
      );
      if (dupe.isNotEmpty) return true;
    }

    await db.insert(AppDatabase.billsTable, {
      'message_id': record.id,
      'bank_id': bank.id,
      'normalized_total_due': meta.normalizedTotalDue,
      'normalized_currency': currency,
      'original_amount': meta.originalAmount,
      'original_currency': meta.originalCurrency,
      'statement_period': statementPeriod,
      'created_at': _nowMs(),
    });
    return true;
  }

  // ---- helpers ------------------------------------------------------------

  Future<bool> _exists(
    DatabaseExecutor db,
    String table,
    int messageId,
  ) async {
    final rows = await db.query(
      table,
      columns: ['id'],
      where: 'message_id = ?',
      whereArgs: [messageId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Bank? _matchByName(List<Bank> banks, String? name) {
    if (name == null) return null;
    final lower = name.toLowerCase();
    for (final b in banks) {
      if (b.name.toLowerCase() == lower) return b;
    }
    return null;
  }
}
