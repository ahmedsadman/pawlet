// 3-month trend metrics from `GET /api/transactions/trends`.

/// Which way a metric moved over the recent window. `isNew` means the prior
/// baseline was empty or too thin to trust (rendered as a "New" chip). Good/bad
/// coloring is applied by the UI, not encoded here.
enum TrendDirection { up, down, flat, isNew }

TrendDirection _parseDirection(String? raw) {
  switch (raw) {
    case 'up':
      return TrendDirection.up;
    case 'down':
      return TrendDirection.down;
    case 'flat':
      return TrendDirection.flat;
    default:
      return TrendDirection.isNew;
  }
}

/// An amount metric (income or spend): last-3-month average with a
/// recent-vs-prior badge and a 6-month sparkline.
class TrendMetric {
  const TrendMetric({
    required this.recentAvg,
    required this.priorAvg,
    required this.changePct,
    required this.direction,
    required this.spark,
  });

  /// Decimal amounts kept as strings for precision.
  final String recentAvg;
  final String priorAvg;

  /// Signed percent change, or null when there is no trustworthy baseline.
  final String? changePct;
  final TrendDirection direction;
  final List<String> spark;

  factory TrendMetric.fromJson(Map<String, dynamic> json) => TrendMetric(
    recentAvg: json['recent_avg'].toString(),
    priorAvg: json['prior_avg'].toString(),
    changePct: json['change_pct']?.toString(),
    direction: _parseDirection(json['direction'] as String?),
    spark: (json['spark'] as List).map((e) => e.toString()).toList(),
  );
}

/// Savings rate (fraction 0..1) with a percentage-point badge. `recent`/`prior`
/// and individual spark entries are null when that window/month had no income.
class SavingsRateTrend {
  const SavingsRateTrend({
    required this.recent,
    required this.prior,
    required this.changePp,
    required this.direction,
    required this.spark,
  });

  final String? recent;
  final String? prior;
  final String? changePp;
  final TrendDirection direction;
  final List<String?> spark;

  factory SavingsRateTrend.fromJson(Map<String, dynamic> json) =>
      SavingsRateTrend(
        recent: json['recent']?.toString(),
        prior: json['prior']?.toString(),
        changePp: json['change_pp']?.toString(),
        direction: _parseDirection(json['direction'] as String?),
        spark: (json['spark'] as List).map((e) => e?.toString()).toList(),
      );
}

/// The full trends payload backing the Trends card.
class Trends {
  const Trends({
    required this.windowMonths,
    required this.sparkMonths,
    required this.income,
    required this.spend,
    required this.savingsRate,
  });

  final int windowMonths;
  final List<DateTime> sparkMonths;
  final TrendMetric income;
  final TrendMetric spend;
  final SavingsRateTrend savingsRate;

  factory Trends.fromJson(Map<String, dynamic> json) => Trends(
    windowMonths: json['window_months'] as int,
    sparkMonths: (json['spark_months'] as List)
        .map((e) => DateTime.parse(e as String))
        .toList(),
    income: TrendMetric.fromJson(json['income'] as Map<String, dynamic>),
    spend: TrendMetric.fromJson(json['spend'] as Map<String, dynamic>),
    savingsRate: SavingsRateTrend.fromJson(
      json['savings_rate'] as Map<String, dynamic>,
    ),
  );
}
