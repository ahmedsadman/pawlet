import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/trends.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../skeleton.dart';
import 'finance_placeholders.dart';
import 'trend_badge.dart';

/// Savings rate fraction (0..1) -> whole-percent label, or `—` when unknown.
String _formatRate(String? fraction) {
  final value = double.tryParse(fraction ?? '');
  if (value == null) return '—';
  return '${(value * 100).round()}%';
}

/// 3-month trend view: Income / Month, Spend / Month and Savings Rate, each
/// with a recent-vs-prior badge. Tapping expands to reveal a 6-month sparkline
/// and the underlying figures. Money is masked when balances are hidden; the
/// rate, badge and sparkline shape stay visible (they leak no absolute amount).
class TrendsCard extends ConsumerStatefulWidget {
  const TrendsCard({super.key});

  @override
  ConsumerState<TrendsCard> createState() => _TrendsCardState();
}

class _TrendsCardState extends ConsumerState<TrendsCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(trendsProvider);
    final trends = async.value?.data;
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final hidden = ref.watch(balanceHiddenProvider);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        // Only interactive once data is loaded (expand reveals sparklines).
        onTap: trends == null
            ? null
            : () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.insights,
                              size: 18,
                              color: AppTheme.flavor.mauve,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Trends',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Last 3 months · vs previous 3 months',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppTheme.flavor.subtext0,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (trends != null)
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.expand_more,
                        color: AppTheme.flavor.subtext0,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              async.when(
                skipLoadingOnReload: true,
                loading: () => const _TrendsSkeleton(),
                error: (_, _) => const FinanceError('Could not load trends.'),
                data: (result) => _tiles(result.data, currency, hidden),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tiles(Trends trends, String currency, bool hidden) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _AmountTile(
        label: 'Income / Month',
        icon: Icons.south_west,
        accent: AppTheme.income,
        metric: trends.income,
        currency: currency,
        hidden: hidden,
        goodWhen: GoodWhen.up,
        expanded: _expanded,
      ),
      const SizedBox(height: 16),
      _AmountTile(
        label: 'Spend / Month',
        icon: Icons.north_east,
        accent: AppTheme.expense,
        metric: trends.spend,
        currency: currency,
        hidden: hidden,
        goodWhen: GoodWhen.down,
        expanded: _expanded,
      ),
      const SizedBox(height: 16),
      _SavingsRateTile(
        trends: trends,
        currency: currency,
        hidden: hidden,
        expanded: _expanded,
      ),
    ],
  );
}

/// An income/spend tile: Title Case label, headline value + badge, and — when
/// expanded — a sparkline plus the recent/prior figures.
class _AmountTile extends StatelessWidget {
  const _AmountTile({
    required this.label,
    required this.icon,
    required this.accent,
    required this.metric,
    required this.currency,
    required this.hidden,
    required this.goodWhen,
    required this.expanded,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final TrendMetric metric;
  final String currency;
  final bool hidden;
  final GoodWhen goodWhen;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 14, color: accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppTheme.flavor.subtext0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(
              formatAmount(metric.recentAvg, currency, hidden: hidden),
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            TrendBadge(
              direction: metric.direction,
              change: metric.changePct,
              unit: '%',
              goodWhen: goodWhen,
            ),
          ],
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          _Sparkline(
            values: metric.spark.map(double.tryParse).toList(),
            color: accent,
          ),
          const SizedBox(height: 4),
          Text(
            'Last 3 mo: ${formatAmount(metric.recentAvg, currency, hidden: hidden)}/mo · '
            'Prior: ${formatAmount(metric.priorAvg, currency, hidden: hidden)}/mo',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.flavor.subtext0,
            ),
          ),
        ],
      ],
    );
  }
}

/// The savings-rate tile: headline percent + points badge, and — when expanded
/// — a zero-based sparkline, the recent/prior rates and net cash per month.
class _SavingsRateTile extends StatelessWidget {
  const _SavingsRateTile({
    required this.trends,
    required this.currency,
    required this.hidden,
    required this.expanded,
  });

  final Trends trends;
  final String currency;
  final bool hidden;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = trends.savingsRate;
    final net =
        (double.tryParse(trends.income.recentAvg) ?? 0) -
        (double.tryParse(trends.spend.recentAvg) ?? 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.savings_outlined,
              size: 14,
              color: AppTheme.flavor.lavender,
            ),
            const SizedBox(width: 6),
            Text(
              'Savings Rate',
              style: theme.textTheme.labelMedium?.copyWith(
                color: AppTheme.flavor.subtext0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(
              _formatRate(rate.recent),
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            TrendBadge(
              direction: rate.direction,
              change: rate.changePp,
              unit: 'pp',
              goodWhen: GoodWhen.up,
            ),
          ],
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          _Sparkline(
            values: rate.spark
                .map((s) => s == null ? null : (double.tryParse(s) ?? 0) * 100)
                .toList(),
            color: AppTheme.flavor.lavender,
            zeroLine: true,
          ),
          const SizedBox(height: 4),
          Text(
            'Last 3 mo: ${_formatRate(rate.recent)} · Prior: ${_formatRate(rate.prior)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.flavor.subtext0,
            ),
          ),
          Text(
            '${formatMoney(net, currency, hidden: hidden)} net/mo',
            style: theme.textTheme.bodySmall?.copyWith(
              color: AppTheme.flavor.subtext0,
            ),
          ),
        ],
      ],
    );
  }
}

/// A minimal trend line: no axes, grid or touch — just the last months' shape.
/// `null` values render as gaps. Tinted to its metric's accent color.
class _Sparkline extends StatelessWidget {
  const _Sparkline({
    required this.values,
    required this.color,
    this.zeroLine = false,
  });

  final List<double?> values;
  final Color color;
  final bool zeroLine;

  @override
  Widget build(BuildContext context) {
    final present = values.whereType<double>().toList();
    if (present.isEmpty) return const SizedBox(height: 36);

    var minY = present.reduce((a, b) => a < b ? a : b);
    var maxY = present.reduce((a, b) => a > b ? a : b);
    if (zeroLine) {
      minY = minY < 0 ? minY : 0;
      maxY = maxY > 0 ? maxY : 0;
    }
    if (minY == maxY) {
      minY -= 1;
      maxY += 1;
    }

    final spots = <FlSpot>[
      for (var i = 0; i < values.length; i++)
        if (values[i] == null)
          FlSpot.nullSpot
        else
          FlSpot(i.toDouble(), values[i]!),
    ];

    return SizedBox(
      height: 36,
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: (values.length - 1).clamp(0, values.length).toDouble(),
          minY: minY,
          maxY: maxY,
          lineTouchData: const LineTouchData(enabled: false),
          titlesData: const FlTitlesData(show: false),
          gridData: const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          extraLinesData: zeroLine
              ? ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: 0,
                      color: color.withValues(alpha: 0.3),
                      strokeWidth: 1,
                    ),
                  ],
                )
              : const ExtraLinesData(),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: color,
              barWidth: 1.5,
              dotData: const FlDotData(show: false),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loading placeholder mirroring the three compact tiles (label + value + badge)
/// so the card reserves its space instead of popping in when data arrives.
class _TrendsSkeleton extends StatelessWidget {
  const _TrendsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(height: 16),
          const _TileSkeleton(),
        ],
      ],
    );
  }
}

class _TileSkeleton extends StatelessWidget {
  const _TileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Skeleton(width: 90, height: 12),
        SizedBox(height: 6),
        Row(
          children: [
            Skeleton(width: 110, height: 22),
            SizedBox(width: 8),
            Skeleton(width: 48, height: 18, borderRadius: 12),
          ],
        ),
      ],
    );
  }
}
