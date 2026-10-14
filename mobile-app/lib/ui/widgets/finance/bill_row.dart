import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bill.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import 'finance_badge.dart';

/// A single credit-card bill: statement period, sender, paid/due status, total. Long-press opens its details.
class BillRow extends ConsumerWidget {
  const BillRow({
    required this.bill,
    required this.currency,
    this.onLongPress,
    super.key,
  });

  final Bill bill;
  final String currency;

  // Opens the bill sheet; allowed even while balances are hidden (the sheet
  // masks amounts and SMS bodies itself).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hidden = ref.watch(balanceHiddenProvider);
    final period = bill.statementPeriod ?? bill.receivedAt.toLocal();

    return InkWell(
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
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
              formatAmount(bill.normalizedTotalDue, currency, hidden: hidden),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
