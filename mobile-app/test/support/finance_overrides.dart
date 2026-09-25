import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/models/finance/bills_page.dart';
import 'package:pawlet/models/finance/summary.dart';
import 'package:pawlet/models/finance/transactions_page.dart';
import 'package:pawlet/models/finance/trends.dart';
import 'package:pawlet/state/finance_providers.dart';

import 'balance_test_overrides.dart';

/// A zeroed Trends payload so TrendsCard renders (no skeleton) in widget tests.
Trends emptyTrends() {
  const metric = TrendMetric(
    recentAvg: '0',
    priorAvg: '0',
    changePct: null,
    direction: TrendDirection.isNew,
    spark: ['0', '0', '0', '0', '0', '0'],
  );
  return Trends(
    windowMonths: 3,
    sparkMonths: List.generate(6, (i) => DateTime(2026, i + 1, 1)),
    income: metric,
    spend: metric,
    savingsRate: const SavingsRateTrend(
      recent: null,
      prior: null,
      changePp: null,
      direction: TrendDirection.isNew,
      spark: [null, null, null, null, null, null],
    ),
  );
}

/// Overrides every finance provider with canned data so the Finance page renders
/// synchronously (no real DB, no lingering skeletons). The heavy sections default
/// to empty; callers supply [banks]/[currency] for the pieces under test.
List<Override> financeOverrides({
  List<Bank> banks = const [],
  String currency = 'BDT',
  bool hidden = false,
}) => [
  overrideBalanceHidden(hidden),
  banksProvider.overrideWith((ref) async => CachedResult(data: banks)),
  currencyProvider.overrideWith((ref) async => CachedResult(data: currency)),
  trendsProvider.overrideWith((ref) async => CachedResult(data: emptyTrends())),
  summaryProvider.overrideWith(
    (ref, range) async => const CachedResult(data: Summary(series: [])),
  ),
  transactionsProvider.overrideWith(
    (ref, query) async => const CachedResult(
      data: TransactionsPage(
        transactions: [],
        total: 0,
        page: 1,
        pageSize: 10,
        totals: Totals(income: '0', expense: '0'),
      ),
    ),
  ),
  billsProvider.overrideWith(
    (ref, bankId) async => const CachedResult(
      data: BillsPage(bills: [], total: 0, page: 1, pageSize: 20),
    ),
  ),
];
