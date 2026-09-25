import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/trends.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/finance_placeholders.dart';
import 'package:pawlet/ui/widgets/finance/trends_card.dart';
import 'package:pawlet/ui/widgets/skeleton.dart';

import 'support/balance_test_overrides.dart';

TrendMetric _metric(
  TrendDirection direction, {
  String recent = '5000.00',
  String prior = '4000.00',
  String? change = '25.0',
}) => TrendMetric(
  recentAvg: recent,
  priorAvg: prior,
  changePct: change,
  direction: direction,
  spark: const ['4000', '4000', '4000', '5000', '5000', '5000'],
);

Trends _trends({
  TrendMetric? income,
  TrendMetric? spend,
  SavingsRateTrend? savingsRate,
}) => Trends(
  windowMonths: 3,
  sparkMonths: [for (var m = 3; m <= 8; m++) DateTime(2025, m, 1)],
  income: income ?? _metric(TrendDirection.up),
  spend:
      spend ??
      _metric(
        TrendDirection.up,
        recent: '1200.00',
        prior: '1000.00',
        change: '20.0',
      ),
  savingsRate:
      savingsRate ??
      const SavingsRateTrend(
        recent: '0.5',
        prior: '0.4',
        changePp: '10.0',
        direction: TrendDirection.up,
        spark: ['0.4', '0.4', '0.4', '0.5', '0.5', '0.5'],
      ),
);

Future<void> _pump(
  WidgetTester tester,
  Trends trends, {
  bool hidden = false,
}) async {
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(hidden),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT', stale: false),
        ),
        trendsProvider.overrideWith(
          (ref) async => CachedResult(data: trends, stale: false),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: TrendsCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'compact view shows the three tiles with values and no sparkline',
    (tester) async {
      await _pump(tester, _trends());

      expect(find.text('Income / Month'), findsOneWidget);
      expect(find.text('Spend / Month'), findsOneWidget);
      expect(find.text('Savings Rate'), findsOneWidget);

      // Headlines + rate.
      expect(find.text('5,000.00 BDT'), findsOneWidget);
      expect(find.text('1,200.00 BDT'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);

      // Sparklines are hidden until expanded.
      expect(find.byType(LineChart), findsNothing);
      expect(find.text('Last 3 months · vs previous 3 months'), findsOneWidget);
    },
  );

  testWidgets('expanding reveals a sparkline per tile and the figures', (
    tester,
  ) async {
    await _pump(tester, _trends());

    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsNWidgets(3));
    expect(find.textContaining('Prior: 4,000.00 BDT/mo'), findsOneWidget);
    expect(find.textContaining('net/mo'), findsOneWidget);
  });

  testWidgets('colors badges by meaning (income up green, spend up red)', (
    tester,
  ) async {
    await _pump(tester, _trends());

    final income = tester.widget<Text>(find.text('25.0%'));
    final spend = tester.widget<Text>(find.text('20.0%'));
    final rate = tester.widget<Text>(find.text('10.0pp'));

    expect(income.style?.color, AppTheme.income);
    expect(spend.style?.color, AppTheme.expense);
    expect(rate.style?.color, AppTheme.income);
  });

  testWidgets('masks money but keeps rate, badge and sparkline when hidden', (
    tester,
  ) async {
    await _pump(tester, _trends(), hidden: true);

    // Income and spend headlines are masked...
    expect(find.text('**** BDT'), findsNWidgets(2));
    expect(find.text('5,000.00 BDT'), findsNothing);
    // ...but the rate percent and badges stay visible (they leak no amount).
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('25.0%'), findsOneWidget);
  });

  testWidgets('shows a New chip when the prior baseline is empty or thin', (
    tester,
  ) async {
    await _pump(
      tester,
      _trends(income: _metric(TrendDirection.isNew, change: null)),
    );

    expect(find.text('New'), findsOneWidget);
  });

  testWidgets('the New chip uses the sky accent (not gray)', (tester) async {
    await _pump(
      tester,
      _trends(income: _metric(TrendDirection.isNew, change: null)),
    );

    final chip = tester.widget<Text>(find.text('New'));
    expect(chip.style?.color, AppTheme.flavor.sky);
  });

  testWidgets('expanded sparklines use per-metric accent colors', (
    tester,
  ) async {
    await _pump(tester, _trends());

    await tester.tap(find.text('Trends'));
    await tester.pumpAndSettle();

    final charts = tester
        .widgetList<LineChart>(find.byType(LineChart))
        .toList();
    expect(charts.length, 3);
    Color barColor(LineChart c) => c.data.lineBarsData.first.color!;
    // Tile order: Income, Spend, Savings.
    expect(barColor(charts[0]), AppTheme.income);
    expect(barColor(charts[1]), AppTheme.expense);
    expect(barColor(charts[2]), AppTheme.flavor.lavender);
  });

  testWidgets('shows a skeleton while trends are loading', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pending = Completer<CachedResult<Trends>>();
    addTearDown(
      () => pending.complete(CachedResult(data: _trends(), stale: false)),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          overrideBalanceHidden(false),
          currencyProvider.overrideWith(
            (ref) async => const CachedResult(data: 'BDT', stale: false),
          ),
          trendsProvider.overrideWith((ref) => pending.future),
        ],
        child: MaterialApp(
          theme: AppTheme.theme,
          home: const Scaffold(body: TrendsCard()),
        ),
      ),
    );
    await tester.pump(); // one frame; the future is intentionally pending

    expect(find.byType(Skeleton), findsWidgets);
    expect(find.text('Income / Month'), findsNothing);
  });

  testWidgets('shows an error state when trends fail to load', (tester) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          overrideBalanceHidden(false),
          currencyProvider.overrideWith(
            (ref) async => const CachedResult(data: 'BDT', stale: false),
          ),
          trendsProvider.overrideWith(
            (ref) => Future<CachedResult<Trends>>.error(Exception('boom')),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.theme,
          home: const Scaffold(body: TrendsCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FinanceError), findsOneWidget);
    expect(find.text('Could not load trends.'), findsOneWidget);
  });
}
