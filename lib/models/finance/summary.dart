/// One month's income/expense totals from `GET /api/transactions/summary`.
class SummaryBucket {
  const SummaryBucket({
    required this.monthStart,
    required this.income,
    required this.expense,
  });

  final DateTime monthStart;

  /// Decimal amounts kept as strings for precision.
  final String income;
  final String expense;

  double get incomeValue => double.tryParse(income) ?? 0;
  double get expenseValue => double.tryParse(expense) ?? 0;

  factory SummaryBucket.fromJson(Map<String, dynamic> json) => SummaryBucket(
    monthStart: DateTime.parse(json['month_start'] as String),
    income: json['income'].toString(),
    expense: json['expense'].toString(),
  );
}

/// Monthly income-vs-expense series backing the summary graph.
class Summary {
  const Summary({required this.series});

  final List<SummaryBucket> series;

  bool get isEmpty => series.isEmpty;

  factory Summary.fromJson(Map<String, dynamic> json) => Summary(
    series: (json['series'] as List)
        .map((e) => SummaryBucket.fromJson(e as Map<String, dynamic>))
        .toList(),
  );
}
