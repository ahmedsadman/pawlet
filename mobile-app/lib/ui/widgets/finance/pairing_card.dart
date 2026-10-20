import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/pairing_suggestion.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import '../expand_reveal.dart';
import 'amount_text.dart';
import 'backing_message.dart';
import 'finance_badge.dart';

/// One pairing-review question: both legs of a suggested pair, how far apart
/// they are, and their backing messages on demand. While balances are hidden
/// the amount difference and the messages (which quote amounts) stay hidden
/// too.
class PairingCard extends ConsumerStatefulWidget {
  const PairingCard({
    required this.suggestion,
    required this.onAnswer,
    super.key,
  });

  final PairingSuggestion suggestion;

  /// Called with true for Yes, false for No.
  final ValueChanged<bool> onAnswer;

  @override
  ConsumerState<PairingCard> createState() => _PairingCardState();
}

class _PairingCardState extends ConsumerState<PairingCard> {
  bool _showMessages = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    final theme = Theme.of(context);
    final f = AppTheme.flavor;
    final hidden = ref.watch(balanceHiddenProvider);
    final isTransfer = s.kind == PairingKind.transfer;
    final messageIds = [s.from.messageId, s.to.messageId].whereType<int>();

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                FinanceBadge(
                  isTransfer ? 'TRANSFER' : 'CARD',
                  color: isTransfer ? f.blue : f.mauve,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isTransfer
                        ? 'Are these one internal transfer?'
                        : 'Did this pay your card?',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _LegRow(leg: s.from, tint: AppTheme.expense),
            _Connector(label: _connectorLabel(s, hidden)),
            _LegRow(leg: s.to, tint: isTransfer ? AppTheme.income : f.mauve),
            if (s.otherMatches > 0) ...[
              const SizedBox(height: 8),
              Text(
                s.otherMatches == 1
                    ? '1 more transaction also matches'
                    : '${s.otherMatches} more transactions also match',
                style: theme.textTheme.bodySmall?.copyWith(color: f.subtext0),
              ),
            ],
            if (messageIds.isNotEmpty && !hidden) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _showMessages = !_showMessages),
                  icon: Icon(
                    _showMessages ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(
                    _showMessages ? 'Hide messages' : 'Show messages',
                  ),
                ),
              ),
              ExpandReveal(
                expanded: _showMessages,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (i, id) in messageIds.indexed) ...[
                        if (i > 0) const SizedBox(height: 12),
                        BackingMessage(id: id),
                      ],
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => widget.onAnswer(false),
                    child: const Text('No'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: () => widget.onAnswer(true),
                    child: const Text('Yes, pair'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _connectorLabel(PairingSuggestion s, bool hidden) {
  final gap = '${gapLabel(s.gap)} apart';
  if (hidden || s.amountDifference == Decimal.zero) return gap;
  final diff = formatAmount(s.amountDifference.toString(), s.from.currency);
  return '$gap · $diff difference';
}

class _LegRow extends StatelessWidget {
  const _LegRow({required this.leg, required this.tint});

  final PairingLeg leg;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = leg.bankName.trim();
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: theme.textTheme.labelLarge?.copyWith(
                color: tint,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  leg.label,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  dateTimeLabel(leg.date),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          AmountText(
            amount: leg.amount,
            currency: leg.currency,
            type: leg.type,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final f = AppTheme.flavor;
    return Padding(
      padding: const EdgeInsets.only(left: 25),
      child: Row(
        children: [
          Container(width: 2, height: 20, color: f.surface1),
          const SizedBox(width: 10),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: f.subtext0),
          ),
        ],
      ),
    );
  }
}
