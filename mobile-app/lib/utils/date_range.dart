/// Date-range presets for the finance graph and transaction filters. Semantics
/// mirror the web frontend's `resolveDateRange` (rolling day windows).
enum DateRangePreset {
  last7Days('last_7_days', 'Last 7 days'),
  thisMonth('this_month', 'This month'),
  lastMonth('last_month', 'Last month'),
  last3Months('last_3_months', 'Last 3 months'),
  lastYear('last_year', 'Last year'),
  thisYear('this_year', 'This Year'),
  allTime('all_time', 'All time');

  const DateRangePreset(this.key, this.label);

  final String key;
  final String label;

  static DateRangePreset fromKey(
    String? key, {
    DateRangePreset fallback = DateRangePreset.thisMonth,
  }) => values.firstWhere((p) => p.key == key, orElse: () => fallback);
}

/// A resolved [from, to] window. Both null means "all time" (no filtering).
/// Value-equal so it can key a Riverpod family without churn.
class DateRange {
  const DateRange({this.from, this.to});

  final DateTime? from;
  final DateTime? to;

  bool get isAll => from == null && to == null;

  @override
  bool operator ==(Object other) =>
      other is DateRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

DateTime _endOfDay(DateTime d) =>
    DateTime(d.year, d.month, d.day, 23, 59, 59, 999);

DateRange _fromDays(DateTime now, int days) => DateRange(
  from: _startOfDay(now.subtract(Duration(days: days))),
  to: _endOfDay(now),
);

/// Resolves a preset to a concrete window. [now] is injectable for tests.
DateRange resolveDateRange(DateRangePreset preset, {DateTime? now}) {
  final n = now ?? DateTime.now();
  switch (preset) {
    case DateRangePreset.allTime:
      return const DateRange();
    case DateRangePreset.last7Days:
      return _fromDays(n, 7);
    case DateRangePreset.thisMonth:
      return DateRange(from: DateTime(n.year, n.month, 1), to: _endOfDay(n));
    case DateRangePreset.lastMonth:
      return _fromDays(n, 30);
    case DateRangePreset.last3Months:
      return _fromDays(n, 90);
    case DateRangePreset.lastYear:
      return _fromDays(n, 365);
    case DateRangePreset.thisYear:
      return DateRange(from: DateTime(n.year), to: _endOfDay(n));
  }
}
