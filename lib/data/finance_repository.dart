import 'package:decimal/decimal.dart';
import 'package:sqflite/sqflite.dart';

import '../models/finance/bank.dart';
import '../models/finance/bill.dart';
import '../models/finance/bills_page.dart';
import '../models/finance/sms_message.dart';
import '../models/finance/summary.dart';
import '../models/finance/transaction.dart';
import '../models/finance/transactions_page.dart';
import '../models/finance/trends.dart';
import '../models/finance/tx_query.dart';
import '../utils/date_range.dart';
import 'database.dart';

/// Wraps a finance read. [stale] is always false locally (kept for UI parity
/// with the server-backed original, which served stale cache on network errors).
class CachedResult<T> {
  const CachedResult({required this.data, this.stale = false, this.fetchedAt});

  final T data;
  final bool stale;
  final DateTime? fetchedAt;
}

/// Reads finance data from the local sqflite database, reproducing the shapes
/// and aggregation the Textgenie backend produced (trends, summary, paginated
/// transactions with totals, bills). Transfers are excluded from income/expense
/// aggregates everywhere, matching the server.
class FinanceRepository {
  FinanceRepository(this._db, {String Function()? currency})
    : _currency = currency ?? (() => 'BDT');

  final Database _db;
  final String Function() _currency;

  // Trend window sizing and "flat" thresholds — mirror backend transactions.py.
  static const int _windowMonths = 3;
  static const int _sparkMonths = 6;
  static final Decimal _flatPct = Decimal.parse('2.0');
  static final Decimal _flatPp = Decimal.parse('1.0');
  static final Decimal _hundred = Decimal.fromInt(100);

  CachedResult<T> _ok<T>(T data) => CachedResult(data: data);

  // ---- simple reads -------------------------------------------------------

  Future<CachedResult<String>> currency() async => _ok(_currency());

  Future<CachedResult<List<Bank>>> banks() async {
    final rows = await _db.query(
      AppDatabase.banksTable,
      orderBy: 'created_at ASC, id ASC',
    );
    return _ok(rows.map(_bankFromRow).toList());
  }

  Future<CachedResult<ApiMessage>> message(int id) async {
    final rows = await _db.query(
      AppDatabase.smsTable,
      columns: ['id', 'sender', 'content', 'timestamp'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    final r = rows.first;
    return _ok(
      ApiMessage(
        id: r['id'] as int,
        sender: r['sender'] as String,
        content: r['content'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(r['timestamp'] as int),
      ),
    );
  }

  // ---- transactions -------------------------------------------------------

  Future<CachedResult<TransactionsPage>> transactions(TxQuery query) async {
    final where = <String>[];
    final args = <Object?>[];
    if (query.from != null) {
      where.add('t.date >= ?');
      args.add(query.from!.millisecondsSinceEpoch);
    }
    if (query.to != null) {
      where.add('t.date <= ?');
      args.add(query.to!.millisecondsSinceEpoch);
    }
    final rangeClause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';

    // Totals: date range only, type filter ignored, transfers excluded.
    final totalsRows = await _db.rawQuery(
      'SELECT type, normalized_amount FROM ${AppDatabase.transactionsTable} t '
      '$rangeClause',
      args,
    );
    var income = Decimal.zero;
    var expense = Decimal.zero;
    for (final row in totalsRows) {
      final type = row['type'] as String;
      final amount = Decimal.parse(row['normalized_amount'] as String);
      if (type == 'income') {
        income += amount;
      } else if (type == 'expense') {
        expense += amount;
      }
    }

    // Type filter applies to the listing + count only.
    final filterWhere = [...where];
    final filterArgs = [...args];
    if (query.types.isNotEmpty) {
      final placeholders = List.filled(query.types.length, '?').join(', ');
      filterWhere.add('t.type IN ($placeholders)');
      filterArgs.addAll(query.types.map((t) => t.value));
    }
    final filterClause = filterWhere.isEmpty
        ? ''
        : 'WHERE ${filterWhere.join(' AND ')}';

    final countRows = await _db.rawQuery(
      'SELECT COUNT(*) c FROM ${AppDatabase.transactionsTable} t $filterClause',
      filterArgs,
    );
    final total = (countRows.first['c'] as int?) ?? 0;

    final orderCol = query.sortBy == 'amount'
        ? 'CAST(t.normalized_amount AS REAL)'
        : 't.date';
    final dir = query.sortDir == 'asc' ? 'ASC' : 'DESC';
    final offset = (query.page - 1) * query.pageSize;

    final rows = await _db.rawQuery('''
      SELECT t.id, t.message_id, t.bank_id,
             b.name AS bank_name, b.account_type AS bank_account_type,
             s.sender AS sender,
             t.normalized_amount, t.normalized_currency,
             t.original_amount, t.original_currency,
             t.type, t.date, t.paired_with_id,
             p.message_id AS paired_with_message_id,
             t.bill_id
      FROM ${AppDatabase.transactionsTable} t
      JOIN ${AppDatabase.smsTable} s ON s.id = t.message_id
      LEFT JOIN ${AppDatabase.banksTable} b ON b.id = t.bank_id
      LEFT JOIN ${AppDatabase.transactionsTable} p ON p.id = t.paired_with_id
      $filterClause
      ORDER BY $orderCol $dir, t.id DESC
      LIMIT ? OFFSET ?
    ''', [...filterArgs, query.pageSize, offset]);

    final items = rows.map(_txFromRow).toList();
    return _ok(
      TransactionsPage(
        transactions: items,
        total: total,
        page: query.page,
        pageSize: query.pageSize,
        totals: Totals(income: income.toString(), expense: expense.toString()),
      ),
    );
  }

  // ---- bills --------------------------------------------------------------

  Future<CachedResult<BillsPage>> bills(
    int bankId, {
    int page = 1,
    int pageSize = 20,
  }) async {
    final countRows = await _db.rawQuery(
      'SELECT COUNT(*) c FROM ${AppDatabase.billsTable} WHERE bank_id = ?',
      [bankId],
    );
    final total = (countRows.first['c'] as int?) ?? 0;

    final offset = (page - 1) * pageSize;
    final rows = await _db.rawQuery('''
      SELECT bl.id, bl.message_id, s.sender AS sender, s.timestamp AS received_at,
             bl.bank_id, b.name AS bank_name,
             bl.normalized_total_due, bl.normalized_currency,
             bl.original_amount, bl.original_currency,
             bl.statement_period, bl.paid_at, bl.created_at
      FROM ${AppDatabase.billsTable} bl
      JOIN ${AppDatabase.smsTable} s ON s.id = bl.message_id
      LEFT JOIN ${AppDatabase.banksTable} b ON b.id = bl.bank_id
      WHERE bl.bank_id = ?
      ORDER BY s.timestamp DESC, bl.id DESC
      LIMIT ? OFFSET ?
    ''', [bankId, pageSize, offset]);

    final billIds = rows.map((r) => r['id'] as int).toList();
    final links = <int, List<int>>{for (final id in billIds) id: []};
    if (billIds.isNotEmpty) {
      final placeholders = List.filled(billIds.length, '?').join(', ');
      final linkRows = await _db.rawQuery(
        'SELECT bill_id, id FROM ${AppDatabase.transactionsTable} '
        'WHERE bill_id IN ($placeholders)',
        billIds,
      );
      for (final row in linkRows) {
        (links[row['bill_id'] as int] ??= []).add(row['id'] as int);
      }
    }

    final bills = rows
        .map((r) => _billFromRow(r, links[r['id'] as int] ?? const []))
        .toList();
    return _ok(
      BillsPage(bills: bills, total: total, page: page, pageSize: pageSize),
    );
  }

  // ---- summary ------------------------------------------------------------

  Future<CachedResult<Summary>> summary(DateRange range) async {
    final totals = await _monthlyIncomeExpense(from: range.from, to: range.to);
    if (totals.isEmpty) return _ok(const Summary(series: []));

    final lower = range.from != null
        ? _monthIndex(range.from!)
        : totals.keys.reduce((a, b) => a < b ? a : b);
    final upper = range.to != null
        ? _monthIndex(range.to!)
        : totals.keys.reduce((a, b) => a > b ? a : b);

    final series = <SummaryBucket>[];
    for (var m = lower; m <= upper; m++) {
      final pair = totals[m];
      series.add(
        SummaryBucket(
          monthStart: _monthIndexToDate(m),
          income: (pair?.$1 ?? Decimal.zero).toString(),
          expense: (pair?.$2 ?? Decimal.zero).toString(),
        ),
      );
    }
    return _ok(Summary(series: series));
  }

  // ---- trends -------------------------------------------------------------

  Future<CachedResult<Trends>> trends() async {
    final totals = await _monthlyIncomeExpense();
    final firstMonth = totals.isEmpty
        ? null
        : totals.keys.reduce((a, b) => a < b ? a : b);

    final now = DateTime.now();
    final currentMonth = _monthIndex(DateTime(now.year, now.month, 1));
    // Oldest -> newest, excluding the current partial month.
    final sparkWindow = [
      for (var o = -_sparkMonths; o < 0; o++) currentMonth + o,
    ];
    final priorWindow = sparkWindow.sublist(0, _windowMonths);
    final recentWindow = sparkWindow.sublist(_windowMonths);

    return _ok(
      Trends(
        windowMonths: _windowMonths,
        sparkMonths: sparkWindow.map(_monthIndexToDate).toList(),
        income: _amountMetric(0, recentWindow, priorWindow, sparkWindow, totals, firstMonth),
        spend: _amountMetric(1, recentWindow, priorWindow, sparkWindow, totals, firstMonth),
        savingsRate: _savingsRateTrend(
          recentWindow,
          priorWindow,
          sparkWindow,
          totals,
          firstMonth,
        ),
      ),
    );
  }

  TrendMetric _amountMetric(
    int idx,
    List<int> recentWindow,
    List<int> priorWindow,
    List<int> sparkWindow,
    Map<int, (Decimal, Decimal)> totals,
    int? firstMonth,
  ) {
    final recent = _windowAverage(idx, recentWindow, totals, firstMonth);
    final prior = _windowAverage(idx, priorWindow, totals, firstMonth);
    String? changePct;
    if (prior.n >= 2 && prior.value != Decimal.zero) {
      changePct =
          _divide((recent.value - prior.value) * _hundred, prior.value, 1)
              .toString();
    }
    return TrendMetric(
      recentAvg: recent.value.toString(),
      priorAvg: prior.value.toString(),
      changePct: changePct,
      direction: _direction(changePct, _flatPct),
      spark: [
        for (final m in sparkWindow) _amountFor(idx, m, totals).toString(),
      ],
    );
  }

  SavingsRateTrend _savingsRateTrend(
    List<int> recentWindow,
    List<int> priorWindow,
    List<int> sparkWindow,
    Map<int, (Decimal, Decimal)> totals,
    int? firstMonth,
  ) {
    final recent = _windowRate(recentWindow, totals, firstMonth);
    final prior = _windowRate(priorWindow, totals, firstMonth);
    String? changePp;
    if (prior.value != null && recent.value != null && prior.n >= 2) {
      changePp = _quantize((recent.value! - prior.value!) * _hundred, 1)
          .toString();
    }
    final spark = <String?>[];
    for (final m in sparkWindow) {
      final inc = _amountFor(0, m, totals);
      final exp = _amountFor(1, m, totals);
      spark.add(inc > Decimal.zero ? _rate(inc, exp).toString() : null);
    }
    return SavingsRateTrend(
      recent: recent.value?.toString(),
      prior: prior.value?.toString(),
      changePp: changePp,
      direction: _direction(changePp, _flatPp),
      spark: spark,
    );
  }

  ({Decimal value, int n}) _windowAverage(
    int idx,
    List<int> window,
    Map<int, (Decimal, Decimal)> totals,
    int? firstMonth,
  ) {
    var sum = Decimal.zero;
    var n = 0;
    for (final m in window) {
      if (firstMonth == null || m < firstMonth) continue;
      n++;
      sum += _amountFor(idx, m, totals);
    }
    final avg = n == 0 ? Decimal.zero : _divide(sum, Decimal.fromInt(n), 2);
    return (value: avg, n: n);
  }

  ({Decimal? value, int n}) _windowRate(
    List<int> window,
    Map<int, (Decimal, Decimal)> totals,
    int? firstMonth,
  ) {
    var sumIncome = Decimal.zero;
    var sumExpense = Decimal.zero;
    var n = 0;
    for (final m in window) {
      if (firstMonth == null || m < firstMonth) continue;
      n++;
      sumIncome += _amountFor(0, m, totals);
      sumExpense += _amountFor(1, m, totals);
    }
    if (sumIncome == Decimal.zero) return (value: null, n: n);
    return (value: _rate(sumIncome, sumExpense), n: n);
  }

  Decimal _rate(Decimal income, Decimal expense) =>
      _divide(income - expense, income, 4);

  TrendDirection _direction(String? change, Decimal flat) {
    if (change == null) return TrendDirection.isNew;
    final value = Decimal.parse(change).abs();
    if (value < flat) return TrendDirection.flat;
    return Decimal.parse(change) > Decimal.zero
        ? TrendDirection.up
        : TrendDirection.down;
  }

  // ---- monthly aggregation ------------------------------------------------

  /// Sum (income, expense) per calendar month keyed by month-index
  /// (`year*12 + month-1`). Transfers excluded. Only months with activity.
  Future<Map<int, (Decimal, Decimal)>> _monthlyIncomeExpense({
    DateTime? from,
    DateTime? to,
  }) async {
    final where = <String>["type IN ('income', 'expense')"];
    final args = <Object?>[];
    if (from != null) {
      where.add('date >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('date <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    final rows = await _db.rawQuery(
      'SELECT date, type, normalized_amount FROM '
      '${AppDatabase.transactionsTable} WHERE ${where.join(' AND ')}',
      args,
    );

    final buckets = <int, (Decimal, Decimal)>{};
    for (final row in rows) {
      final ms = row['date'] as int;
      final key = _monthIndex(DateTime.fromMillisecondsSinceEpoch(ms));
      final amount = Decimal.parse(row['normalized_amount'] as String);
      final current = buckets[key] ?? (Decimal.zero, Decimal.zero);
      if (row['type'] == 'income') {
        buckets[key] = (current.$1 + amount, current.$2);
      } else {
        buckets[key] = (current.$1, current.$2 + amount);
      }
    }
    return buckets;
  }

  Decimal _amountFor(int idx, int month, Map<int, (Decimal, Decimal)> totals) {
    final pair = totals[month];
    if (pair == null) return Decimal.zero;
    return idx == 0 ? pair.$1 : pair.$2;
  }

  // ---- helpers ------------------------------------------------------------

  int _monthIndex(DateTime d) => d.year * 12 + (d.month - 1);

  DateTime _monthIndexToDate(int index) =>
      DateTime(index ~/ 12, (index % 12) + 1, 1);

  Decimal _divide(Decimal a, Decimal b, int scale) =>
      _quantize((a / b).toDecimal(scaleOnInfinitePrecision: scale + 8), scale);

  Decimal _quantize(Decimal d, int scale) => d.round(scale: scale);

  Bank _bankFromRow(Map<String, Object?> row) => Bank(
    id: row['id'] as int,
    name: row['name'] as String,
    accountType: row['account_type'] as String,
    cardDigits: row['card_digits'] as String?,
    lastBalance: row['last_balance'] as String?,
    lastBalanceAt: row['last_balance_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(row['last_balance_at'] as int),
    createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
  );

  TransactionItem _txFromRow(Map<String, Object?> row) => TransactionItem(
    id: row['id'] as int,
    messageId: row['message_id'] as int,
    bankId: row['bank_id'] as int?,
    bankName: row['bank_name'] as String?,
    bankAccountType: row['bank_account_type'] as String?,
    sender: row['sender'] as String,
    normalizedAmount: row['normalized_amount'] as String,
    normalizedCurrency: row['normalized_currency'] as String,
    originalAmount: row['original_amount'] as String?,
    originalCurrency: row['original_currency'] as String?,
    type: TxType.fromValue(row['type'] as String),
    date: DateTime.fromMillisecondsSinceEpoch(row['date'] as int),
    pairedWithId: row['paired_with_id'] as int?,
    pairedWithMessageId: row['paired_with_message_id'] as int?,
    billId: row['bill_id'] as int?,
  );

  Bill _billFromRow(Map<String, Object?> row, List<int> linkedTransactionIds) =>
      Bill(
        id: row['id'] as int,
        messageId: row['message_id'] as int,
        sender: row['sender'] as String,
        receivedAt: DateTime.fromMillisecondsSinceEpoch(
          row['received_at'] as int,
        ),
        bankId: row['bank_id'] as int?,
        bankName: row['bank_name'] as String?,
        normalizedTotalDue: row['normalized_total_due'] as String,
        normalizedCurrency: row['normalized_currency'] as String,
        originalAmount: row['original_amount'] as String?,
        originalCurrency: row['original_currency'] as String?,
        statementPeriod: row['statement_period'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['statement_period'] as int),
        paidAt: row['paid_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['paid_at'] as int),
        linkedTransactionIds: linkedTransactionIds,
        createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      );
}
