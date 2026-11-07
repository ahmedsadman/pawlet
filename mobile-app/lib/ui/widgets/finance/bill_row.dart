import 'package:flutter/material.dart';

import '../../../models/finance/bill.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import 'finance_badge.dart';

/// A single credit-card bill: statement period, sender, paid/due status,
/// total. Long-press opens its details. Without [onLongPress] it builds no ink
/// of its own, so a parent can make it part of a larger tappable surface.
class BillRow extends StatelessWidget {
  const BillRow({
    required this.bill,
    required this.currency,
    this.onLongPress,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    super.key,
  });

  final Bill bill;
  final String currency;

  // Inside the ink, so a horizontal inset still lets the ink run edge to edge.
  final EdgeInsetsGeometry padding;

  // Opens the bill sheet.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = bill.statementPeriod ?? bill.receivedAt.toLocal();

    final content = Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  monthYearLabel(period),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    FinanceBadge(bill.sender),
                    bill.isPaid
                        ? FinanceBadge('Paid', color: AppTheme.income)
                        : FinanceBadge('Due', color: AppTheme.flavor.peach),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatAmount(bill.normalizedTotalDue, currency),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    if (onLongPress == null) return content;
    return InkWell(onLongPress: onLongPress, child: content);
  }
}
