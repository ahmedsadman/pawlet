import 'transaction.dart';

/// Per-type sums for the current filter (transfers excluded).
class Totals {
  const Totals({required this.income, required this.expense});

  final String income;
  final String expense;

  factory Totals.fromJson(Map<String, dynamic> json) => Totals(
    income: json['income'].toString(),
    expense: json['expense'].toString(),
  );
}

/// A page of transactions from `GET /api/transactions`.
class TransactionsPage {
  const TransactionsPage({
    required this.transactions,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.totals,
  });

  final List<TransactionItem> transactions;
  final int total;
  final int page;
  final int pageSize;
  final Totals totals;

  int get totalPages =>
      pageSize <= 0 ? 1 : (total / pageSize).ceil().clamp(1, 1 << 30);

  factory TransactionsPage.fromJson(Map<String, dynamic> json) =>
      TransactionsPage(
        transactions: (json['transactions'] as List)
            .map((e) => TransactionItem.fromJson(e as Map<String, dynamic>))
            .toList(),
        total: json['total'] as int,
        page: json['page'] as int,
        pageSize: json['page_size'] as int,
        totals: Totals.fromJson(json['totals'] as Map<String, dynamic>),
      );
}
