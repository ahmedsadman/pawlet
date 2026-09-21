import 'package:meowni/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Opens a fresh in-memory database with the app schema (ffi-backed for tests).
Future<Database> openTestDb() {
  return databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: AppDatabase.createSchema,
      // Each opened handle is its own in-memory DB — no sharing across tests.
      singleInstance: false,
    ),
  );
}

Future<int> insertSms(
  Database db, {
  required String sender,
  String content = 'msg',
  required int ts,
  String status = 'success',
}) {
  return db.insert(AppDatabase.smsTable, {
    'sender': sender,
    'content': content,
    'timestamp': ts,
    'status': status,
    'updated_at': ts,
  });
}

Future<int> insertBank(
  Database db, {
  required String name,
  String accountType = 'deposit',
  String? cardDigits,
  String? lastBalance,
  int? lastBalanceAt,
  int createdAt = 0,
  String? alternateNames,
  String? matchTokens,
}) {
  return db.insert(AppDatabase.banksTable, {
    'name': name,
    'account_type': accountType,
    'card_digits': cardDigits,
    'last_balance': lastBalance,
    'last_balance_at': lastBalanceAt,
    'created_at': createdAt,
    'alternate_names': alternateNames,
    'match_tokens': matchTokens,
  });
}

Future<int> insertTx(
  Database db, {
  required int messageId,
  int? bankId,
  int? pairedWithId,
  int? billId,
  required String amount,
  String currency = 'BDT',
  String? originalAmount,
  String? originalCurrency,
  required String type,
  required DateTime date,
}) {
  return db.insert(AppDatabase.transactionsTable, {
    'message_id': messageId,
    'bank_id': bankId,
    'paired_with_id': pairedWithId,
    'bill_id': billId,
    'normalized_amount': amount,
    'normalized_currency': currency,
    'original_amount': originalAmount,
    'original_currency': originalCurrency,
    'type': type,
    'date': date.millisecondsSinceEpoch,
    'created_at': date.millisecondsSinceEpoch,
  });
}

Future<int> insertBill(
  Database db, {
  required int messageId,
  int? bankId,
  required String totalDue,
  String currency = 'BDT',
  DateTime? statementPeriod,
  DateTime? paidAt,
  int createdAt = 0,
}) {
  return db.insert(AppDatabase.billsTable, {
    'message_id': messageId,
    'bank_id': bankId,
    'normalized_total_due': totalDue,
    'normalized_currency': currency,
    'statement_period': statementPeriod?.millisecondsSinceEpoch,
    'paid_at': paidAt?.millisecondsSinceEpoch,
    'created_at': createdAt,
  });
}
