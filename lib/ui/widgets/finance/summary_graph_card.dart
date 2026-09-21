import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/summary.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/chart_axis.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/date_range.dart';
import '../../../utils/time_format.dart';
import '../section_header.dart';
import '../skeleton.dart';
import 'date_range_selector.dart';
import 'finance_placeholders.dart';

/// Monthly income-vs-expense area chart with gradient fills, themed to
/// Catppuccin (income = green, expense = red).
class SummaryGraphCard extends ConsumerStatefulWidget {
  const SummaryGraphCard({super.key});

  @override
  ConsumerState<SummaryGraphCard> createState() => _SummaryGraphCardState();
}

class _SummaryGraphCardState extends ConsumerState<SummaryGraphCard> {
  late DateRangePreset _preset;

  @override
  void initState() {
    super.initState();
    // Restore the last-used range (defaults to last year on first run).
    _preset = DateRangePreset.fromKey(
      ref.read(settingsRepositoryProvider).summaryRange,
      fallback: DateRangePreset.lastYear,
    );
  }

  void _selectPreset(DateRangePreset preset) {
    setState(() => _preset = preset);
    ref.read(settingsRepositoryProvider).setSummaryRange(preset.key);
  }

  @override
  Widget build(BuildContext context) {
    final range = resolveDateRange(_preset);
    final async = ref.watch(summaryProvider(range));
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final hidden = ref.watch(balanceHiddenProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: SectionHeader('Summary Graph')),
            DateRangeSelector(value: _preset, onSelected: _selectPreset),
          ],
        ),
        // Breathing room so the top Y-axis label doesn't crowd the title.
        const SizedBox(height: 12),
        SizedBox(
          height: 260,
          child: hidden
              ? const _HiddenChart()
              : async.when(
                  loading: () => const SummaryChartSkeleton(),
                  error: (_, _) =>
                      const FinanceError('Could not load the graph.'),
                  data: (result) => result.data.isEmpty
                      ? const Center(
                          child: EmptyHint(
                            'No transactions in selected range.',
                          ),
                        )
                      : _Chart(summary: result.data, currency: currency),
                ),
        ),
        const SizedBox(height: 8),
        if (!hidden) const _Legend(),
      ],
    );
  }
}

/// Shown in place of the chart when balances are hidden: a dimmed, data-less
/// axes+grid skeleton in the background with a fully-visible "hidden" indicator
/// blocking the view in the foreground. The skeleton carries no real values (no
/// data lines, no numeric axis labels) so nothing leaks.
class _HiddenChart extends StatelessWidget {
  const _HiddenChart();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: Opacity(
            opacity: 0.3,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: 6,
                minY: 0,
                maxY: 100,
                lineBarsData: const [],
                lineTouchData: const LineTouchData(enabled: false),
                titlesData: const FlTitlesData(show: false),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: true,
                  horizontalInterval: 20,
                  verticalInterval: 1,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: theme.colorScheme.outlineVariant,
                    strokeWidth: 1,
                  ),
                  getDrawingVerticalLine: (_) => FlLine(
                    color: theme.colorScheme.outlineVariant,
                    strokeWidth: 1,
                  ),
                ),
                borderData: FlBorderData(
                  show: true,
                  border: Border(
                    left: BorderSide(color: theme.colorScheme.outline),
                    bottom: BorderSide(color: theme.colorScheme.outline),
                  ),
                ),
              ),
            ),
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.visibility_off_outlined,
                size: 32,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 8),
              Text(
                'Amounts hidden',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  const _Chart({required this.summary, required this.currency});

  final Summary summary;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buckets = summary.series;
    final labelEvery = (buckets.length / 6).ceil().clamp(1, buckets.length);

    // A rounded value axis with headroom so the curve can't spill past the top
    // edge and the top label stays on a clean round value (no "407.5K"/"400K"
    // collision).
    final dataMax = buckets.fold<double>(
      0,
      (m, b) =>
          [m, b.incomeValue, b.expenseValue].reduce((a, c) => a > c ? a : c),
    );
    final axis = niceAxis(dataMax);

    LineChartBarData bar(List<FlSpot> spots, Color color) => LineChartBarData(
      spots: spots,
      color: color,
      isCurved: true,
      preventCurveOverShooting: true,
      barWidth: 2,
      dotData: FlDotData(
        show: true,
        getDotPainter: (spot, percent, barData, index) =>
            FlDotCirclePainter(radius: 2.5, color: color, strokeWidth: 0),
      ),
      belowBarData: BarAreaData(
        show: true,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.4), color.withValues(alpha: 0.0)],
        ),
      ),
    );

    final incomeSpots = <FlSpot>[
      for (var i = 0; i < buckets.length; i++)
        FlSpot(i.toDouble(), buckets[i].incomeValue),
    ];
    final expenseSpots = <FlSpot>[
      for (var i = 0; i < buckets.length; i++)
        FlSpot(i.toDouble(), buckets[i].expenseValue),
    ];

    final lastX = (buckets.length - 1).clamp(0, buckets.length).toDouble();

    return Padding(
      // A small horizontal inset so points near the right edge stay comfortably
      // tappable rather than flush against the edge.
      padding: const EdgeInsets.only(right: 6),
      child: LineChart(
        LineChartData(
          // Data spans the full plot width, edge to edge (no wasted margin).
          minX: 0,
          maxX: lastX,
          minY: 0,
          maxY: axis.max,
          // Clip only top/bottom to contain any vertical curve overshoot; leave
          // left/right unclipped.
          clipData: const FlClipData(
            top: true,
            bottom: true,
            left: false,
            right: false,
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: axis.step,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: theme.colorScheme.outlineVariant, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: axis.step,
                reservedSize: 44,
                getTitlesWidget: (value, meta) => SideTitleWidget(
                  meta: meta,
                  fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                  child: Text(
                    formatCompact(value),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                // One tick per bucket (integer x). Without this fl_chart samples
                // at fractional x and rounds to the same index twice, producing
                // duplicate labels like "Jul 26" back-to-back.
                interval: 1,
                reservedSize: 24,
                getTitlesWidget: (value, meta) {
                  final i = value.round();
                  if (i < 0 || i >= buckets.length) {
                    return const SizedBox.shrink();
                  }
                  if (i % labelEvery != 0) return const SizedBox.shrink();
                  return SideTitleWidget(
                    meta: meta,
                    space: 6,
                    // Nudge the first/last labels inward so they stay within the
                    // chart instead of overflowing the edge (e.g. "Sep 26").
                    fitInside: SideTitleFitInsideData.fromTitleMeta(meta),
                    child: Text(
                      monthYearLabel(buckets[i].monthStart),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          lineTouchData: LineTouchData(
            handleBuiltInTouches: true,
            // Snap to the nearest point by x, so holding anywhere on the chart
            // (not just exactly on a point) shows that month's tooltip.
            touchSpotThreshold: 20,
            distanceCalculator: (touch, spot) => (touch.dx - spot.dx).abs(),
            getTouchedSpotIndicator: (barData, spotIndexes) => [
              for (final _ in spotIndexes)
                TouchedSpotIndicatorData(
                  FlLine(color: theme.colorScheme.outline, strokeWidth: 1),
                  FlDotData(
                    show: true,
                    getDotPainter: (spot, percent, bar, index) =>
                        FlDotCirclePainter(
                          radius: 4,
                          color: barData.color ?? theme.colorScheme.primary,
                          strokeWidth: 2,
                          strokeColor: theme.colorScheme.surface,
                        ),
                  ),
                ),
            ],
            touchTooltipData: LineTouchTooltipData(
              // Keep the floating tooltip within the chart bounds instead of
              // spilling off the right/top edge on the last points.
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipColor: (_) => theme.colorScheme.surfaceContainerHighest,
              // Comma-formatted, right-aligned values (matching transaction
              // amounts) so they read cleanly; colored per series.
              getTooltipItems: (touchedSpots) => [
                for (final spot in touchedSpots)
                  LineTooltipItem(
                    formatMoney(spot.y, currency),
                    theme.textTheme.labelMedium!.copyWith(
                      color: spot.bar.color ?? theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.right,
                  ),
              ],
            ),
          ),
          lineBarsData: [
            bar(incomeSpots, AppTheme.income),
            bar(expenseSpots, AppTheme.expense),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _dot(context, AppTheme.income, 'Income'),
        const SizedBox(width: 16),
        _dot(context, AppTheme.expense, 'Expense'),
      ],
    );
  }

  Widget _dot(BuildContext context, Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: Theme.of(context).textTheme.labelMedium),
    ],
  );
}
