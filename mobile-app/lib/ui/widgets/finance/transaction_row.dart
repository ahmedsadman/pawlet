import 'package:flutter/material.dart';

import '../../../models/finance/transaction.dart';
import '../../../utils/time_format.dart';
import '../expand_reveal.dart';
import 'amount_text.dart';
import 'backing_message.dart';
import 'finance_badge.dart';

/// A transaction list row. Tapping toggles an expanded panel showing the
/// backing SMS message (and its paired counterpart for transfers). Manual rows
/// (no backing SMS) show a "Manual" badge and do not expand.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    required this.tx,
    required this.currency,
    required this.expanded,
    required this.onTap,
    this.onLongPress,
    super.key,
  });

  final TransactionItem tx;
  final String currency;
  final bool expanded;
  // Null disables expansion (e.g. while balances are hidden, so the backing SMS
  // — which usually contains the amount — can't be revealed).
  final VoidCallback? onTap;
  // Long-press opens the change-type sheet; independent of [onTap]/hidden.
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tx.sender,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (tx.messageId == null)
                            const FinanceBadge('Manual'),
                          if (tx.isCreditCard) const FinanceBadge('Credit'),
                          if (tx.pairedWithId != null)
                            Icon(
                              Icons.swap_horiz,
                              size: 14,
                              color: theme.colorScheme.outline,
                            ),
                          if (tx.billId != null)
                            Icon(
                              Icons.receipt_long_outlined,
                              size: 14,
                              color: theme.colorScheme.outline,
                            ),
                          Text(
                            dateTimeLabel(tx.date),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AmountText(
                  amount: tx.normalizedAmount,
                  currency: currency,
                  type: tx.type,
                ),
              ],
            ),
          ),
        ),
        ExpandReveal(
          expanded: expanded && tx.messageId != null,
          child: _MessagePanel(tx: tx),
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _MessagePanel extends StatelessWidget {
  const _MessagePanel({required this.tx});

  final TransactionItem tx;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tx.message case final message?) BackingMessage(message),
          if (tx.pairedMessage case final paired?) ...[
            if (tx.message != null) const SizedBox(height: 12),
            BackingMessage(paired),
          ],
        ],
      ),
    );
  }
}
