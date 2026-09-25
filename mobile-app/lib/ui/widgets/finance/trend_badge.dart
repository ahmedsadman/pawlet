import 'package:flutter/material.dart';

import '../../../models/finance/trends.dart';
import '../../../theme/catppuccin_theme.dart';

/// Which movement direction is financially healthy for a metric.
enum GoodWhen { up, down }

/// A compact trend indicator: an arrow + delta, colored by *meaning* — spending
/// going up is bad (red), income or the savings rate going up is good (green).
/// Flat and new carry no verdict and stay muted.
class TrendBadge extends StatelessWidget {
  const TrendBadge({
    super.key,
    required this.direction,
    required this.change,
    required this.unit,
    required this.goodWhen,
  });

  final TrendDirection direction;

  /// Signed change magnitude from the API (e.g. "25.0" / "-5.0"), or null.
  final String? change;

  /// Suffix after the number: "%" for amounts, "pp" for the savings rate.
  final String unit;
  final GoodWhen goodWhen;

  Color _color(BuildContext context) {
    switch (direction) {
      case TrendDirection.isNew:
        return AppTheme.flavor.sky;
      case TrendDirection.flat:
        return Theme.of(context).colorScheme.outline;
      case TrendDirection.up:
        return goodWhen == GoodWhen.up ? AppTheme.income : AppTheme.expense;
      case TrendDirection.down:
        return goodWhen == GoodWhen.down ? AppTheme.income : AppTheme.expense;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: color,
      fontWeight: FontWeight.w600,
    );

    if (direction == TrendDirection.isNew) {
      return Text('New', style: style);
    }
    if (direction == TrendDirection.flat) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.remove, size: 14, color: color),
          const SizedBox(width: 2),
          Text('Steady', style: style),
        ],
      );
    }

    final icon = direction == TrendDirection.up
        ? Icons.arrow_upward
        : Icons.arrow_downward;
    final magnitude = change == null
        ? ''
        : (double.tryParse(change!)?.abs().toStringAsFixed(1) ?? '');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 2),
        Text('$magnitude$unit', style: style),
      ],
    );
  }
}
