import 'package:sqflite/sqflite.dart';

import '../models/finance/bank.dart';
import '../utils/bank_tokens.dart';
import 'database.dart';

/// CRUD for user-managed bank accounts (deposit) and credit cards.
class BanksRepository {
  BanksRepository(this._db, {int Function()? nowMs})
    : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Database _db;
  final int Function() _nowMs;

  static const _table = AppDatabase.banksTable;

  /// Inserts a bank and returns it with its assigned id. [alternateNames] is
  /// free text (comma/newline separated); its match tokens are precomputed here.
  Future<Bank> create({
    required String name,
    String accountType = 'deposit',
    String? cardDigits,
    String? lastBalance,
    int? lastBalanceAt,
    String alternateNames = '',
  }) async {
    final createdAt = _nowMs();
    final id = await _db.insert(_table, {
      'name': name,
      'account_type': accountType,
      'card_digits': cardDigits,
      'last_balance': lastBalance,
      'last_balance_at': lastBalanceAt,
      'created_at': createdAt,
      'alternate_names': alternateNames,
      'match_tokens': buildMatchTokens(name, alternateNames).join(' '),
    });
    return (await getById(id))!;
  }

  Future<List<Bank>> list() async {
    final rows = await _db.query(_table, orderBy: 'created_at ASC, id ASC');
    return rows.map(_fromRow).toList();
  }

  Future<Bank?> getById(int id) async {
    final rows = await _db.query(
      _table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.first);
  }

  /// Updates the mutable fields of a bank. Only provided args are written. When
  /// [name] or [alternateNames] changes, the match tokens are recomputed.
  Future<Bank?> update(
    int id, {
    String? name,
    String? accountType,
    String? cardDigits,
    bool clearCardDigits = false,
    String? lastBalance,
    bool clearLastBalance = false,
    int? lastBalanceAt,
    String? alternateNames,
  }) async {
    final values = <String, Object?>{};
    if (name != null) values['name'] = name;
    if (accountType != null) values['account_type'] = accountType;
    if (clearCardDigits) {
      values['card_digits'] = null;
    } else if (cardDigits != null) {
      values['card_digits'] = cardDigits;
    }
    if (clearLastBalance) {
      values['last_balance'] = null;
    } else if (lastBalance != null) {
      values['last_balance'] = lastBalance;
    }
    if (lastBalanceAt != null) values['last_balance_at'] = lastBalanceAt;

    // Recompute match tokens whenever the name or alternate names change.
    if (name != null || alternateNames != null) {
      final current = await getById(id);
      if (current == null) return null;
      final newName = name ?? current.name;
      final newAlternates = alternateNames ?? current.alternateNames;
      values['alternate_names'] = newAlternates;
      values['match_tokens'] = buildMatchTokens(newName, newAlternates).join(' ');
    }

    if (values.isNotEmpty) {
      await _db.update(_table, values, where: 'id = ?', whereArgs: [id]);
    }
    return getById(id);
  }

  Future<void> delete(int id) async {
    await _db.delete(_table, where: 'id = ?', whereArgs: [id]);
  }

  Bank _fromRow(Map<String, Object?> row) => Bank(
    id: row['id'] as int,
    name: row['name'] as String,
    accountType: row['account_type'] as String,
    cardDigits: row['card_digits'] as String?,
    lastBalance: row['last_balance'] as String?,
    lastBalanceAt: row['last_balance_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_balance_at'] as int),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
    alternateNames: (row['alternate_names'] as String?) ?? '',
    matchTokens: matchTokensFromColumn(row['match_tokens'] as String?),
  );
}
