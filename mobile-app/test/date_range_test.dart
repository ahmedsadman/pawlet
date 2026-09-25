import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/utils/date_range.dart';

void main() {
  final now = DateTime(2025, 6, 15, 10, 30);

  test('all time resolves to an empty window', () {
    final range = resolveDateRange(DateRangePreset.allTime, now: now);
    expect(range.from, isNull);
    expect(range.to, isNull);
    expect(range.isAll, isTrue);
  });

  test('last 7 days spans from start-of-day 7 days ago to end of today', () {
    final range = resolveDateRange(DateRangePreset.last7Days, now: now);
    expect(range.from, DateTime(2025, 6, 8));
    expect(range.to, DateTime(2025, 6, 15, 23, 59, 59, 999));
  });

  test('this month starts at the first of the month', () {
    final range = resolveDateRange(DateRangePreset.thisMonth, now: now);
    expect(range.from, DateTime(2025, 6, 1));
    expect(range.to, DateTime(2025, 6, 15, 23, 59, 59, 999));
  });

  test('last month is a rolling 30-day window (matches web)', () {
    final range = resolveDateRange(DateRangePreset.lastMonth, now: now);
    expect(range.from, DateTime(2025, 5, 16));
    expect(range.to, DateTime(2025, 6, 15, 23, 59, 59, 999));
  });

  test('this year starts at the first day of the current year', () {
    final range = resolveDateRange(DateRangePreset.thisYear, now: now);
    expect(range.from, DateTime(2025, 1, 1));
    expect(range.to, DateTime(2025, 6, 15, 23, 59, 59, 999));
  });

  test('fromKey maps known keys and falls back otherwise', () {
    expect(DateRangePreset.fromKey('last_year'), DateRangePreset.lastYear);
    expect(DateRangePreset.fromKey(null), DateRangePreset.thisMonth);
    expect(DateRangePreset.fromKey('nonsense'), DateRangePreset.thisMonth);
  });

  test('DateRange is value-equal', () {
    final a = resolveDateRange(DateRangePreset.thisMonth, now: now);
    final b = resolveDateRange(DateRangePreset.thisMonth, now: now);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
