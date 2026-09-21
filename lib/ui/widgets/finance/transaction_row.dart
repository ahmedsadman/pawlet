import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/transaction.dart';
import '../../../state/finance_providers.dart';
import '../../../utils/time_format.dart';
import '../skeleton.dart';
import 'amount_text.dart';
import 'finance_badge.dart';
import 'finance_placeholders.dart';

/// A transaction list row. Tapping toggles an expanded panel showing the
/// backing SMS message (and its paired counterpart for transfers).
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    required this.tx,
    required this.currency,
    required this.expanded,
    required this.onTap,
    super.key,
  });

  final TransactionItem tx;
  final String currency;
  final bool expanded;
  // Null disables expansion (e.g. while balances are hidden, so the backing SMS
  // — which usually contains the amount — can't be revealed).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        InkWell(
          onTap: onTap,
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
                            relativeTime(tx.date.toLocal()),
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
        if (expanded) _MessagePanel(tx: tx),
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
          _Message(id: tx.messageId),
          if (tx.pairedWithMessageId != null) ...[
            const SizedBox(height: 12),
            _Message(id: tx.pairedWithMessageId!),
          ],
        ],
      ),
    );
  }
}

class _Message extends ConsumerWidget {
  const _Message({required this.id});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(messageProvider(id));
    return async.when(
      loading: () => const MessageLinesSkeleton(),
      error: (_, _) => FinanceError(
        'Could not load the message.',
        onRetry: () => ref.invalidate(messageProvider(id)),
      ),
      data: (result) {
        final message = result.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.sender,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 2),
            Text(message.content, style: theme.textTheme.bodySmall),
          ],
        );
      },
    );
  }
}
