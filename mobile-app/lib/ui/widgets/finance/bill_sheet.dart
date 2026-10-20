import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bill.dart';
import '../../../models/finance/transaction.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import '../skeleton.dart';
import 'backing_message.dart';
import 'finance_badge.dart';
import 'finance_placeholders.dart';

/// Long-press handler for a bill: retires the one-time hint, then opens
/// [BillSheet].
Future<void> showBillSheet(BuildContext context, WidgetRef ref, Bill bill) {
  ref.read(billHintSeenProvider.notifier).markSeen();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => BillSheet(bill: bill),
  );
}

/// A bill's details: header, the bill SMS, its linked payment legs grouped as
/// "Paid from" (the funding bank debit) and "Payment received" (the card's own
/// leg), and a Mark paid / Mark unpaid action. SMS bodies are withheld while
/// balances are hidden (they carry amounts); the action stays available.
class BillSheet extends ConsumerStatefulWidget {
  const BillSheet({required this.bill, super.key});

  final Bill bill;

  @override
  ConsumerState<BillSheet> createState() => _BillSheetState();
}

class _BillSheetState extends ConsumerState<BillSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _toggle() async {
    final bill = widget.bill;
    final markPaid = !bill.isPaid;
    if (!markPaid && bill.linkedTransactionIds.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Mark as unpaid?'),
          content: const Text(
            "This unlinks the payment. Pawlet won't auto-match this bill again.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Unlink'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final revision = ref.read(dataRevisionProvider.notifier);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(billActionsProvider).setPaid(bill.id, paid: markPaid);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = "Couldn't save that. Try again.";
        });
      }
      return;
    }
    revision.bump();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final bill = widget.bill;
    final hidden = ref.watch(balanceHiddenProvider);
    final currency =
        ref.watch(currencyProvider).value?.data ?? bill.normalizedCurrency;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(bill: bill, currency: currency, hidden: hidden),
              const SizedBox(height: 16),
              const _Label('Bill SMS'),
              _MessageBox(
                hidden: hidden,
                child: BackingMessage(id: bill.messageId),
              ),
              if (bill.linkedTransactionIds.isNotEmpty)
                _PaymentLegs(
                  billId: bill.id,
                  cardBankId: bill.bankId,
                  currency: currency,
                  hidden: hidden,
                ),
              const SizedBox(height: 24),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _toggle,
                icon: Icon(bill.isPaid ? Icons.undo : Icons.check),
                label: Text(bill.isPaid ? 'Mark unpaid' : 'Mark paid'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.bill,
    required this.currency,
    required this.hidden,
  });

  final Bill bill;
  final String currency;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = bill.statementPeriod ?? bill.receivedAt.toLocal();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                bill.bankName ?? bill.sender,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                monthYearLabel(period),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  bill.isPaid
                      ? FinanceBadge('Paid', color: AppTheme.income)
                      : FinanceBadge('Due', color: AppTheme.flavor.peach),
                  if (bill.paidAt != null)
                    Text(
                      'Paid on ${dateLabel(bill.paidAt!)}',
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
        Text(
          formatAmount(bill.normalizedTotalDue, currency, hidden: hidden),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// The expanded-transaction panel styling around an SMS; a placeholder line
/// instead while balances are hidden.
class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.hidden, required this.child});

  final bool hidden;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: hidden
          ? Text(
              'Hidden while balances are hidden.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            )
          : child,
    );
  }
}

class _PaymentLegs extends ConsumerWidget {
  const _PaymentLegs({
    required this.billId,
    required this.cardBankId,
    required this.currency,
    required this.hidden,
  });

  final int billId;

  /// The bill's card. Legs on it are the payment the card received; every
  /// other leg (a bank debit, or a manual entry) is what paid it.
  final int? cardBankId;
  final String currency;
  final bool hidden;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(billTransactionsProvider(billId));
    return async.when(
      loading: () => const MessageLinesSkeleton(),
      error: (_, _) => const FinanceError('Could not load the payment.'),
      data: (legs) {
        bool onCard(TransactionItem l) =>
            l.bankId != null && l.bankId == cardBankId;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ..._group(context, 'Paid from', [
              for (final l in legs)
                if (!onCard(l)) l,
            ]),
            ..._group(context, 'Payment received', [
              for (final l in legs)
                if (onCard(l)) l,
            ]),
          ],
        );
      },
    );
  }

  /// A labelled run of legs, or nothing when [legs] is empty.
  List<Widget> _group(
    BuildContext context,
    String label,
    List<TransactionItem> legs,
  ) => [
    if (legs.isNotEmpty) ...[
      const SizedBox(height: 16),
      _Label(label),
      for (var i = 0; i < legs.length; i++) ...[
        if (i > 0) const SizedBox(height: 8),
        _leg(context, legs[i]),
      ],
    ],
  ];

  Widget _leg(BuildContext context, TransactionItem leg) {
    if (leg.messageId != null) {
      return _MessageBox(
        hidden: hidden,
        child: BackingMessage(id: leg.messageId!),
      );
    }
    // Manual leg: no SMS to show, so summarise the row instead.
    final theme = Theme.of(context);
    return Text(
      '${leg.bankName ?? leg.sender} · '
      '${formatAmount(leg.normalizedAmount, currency, hidden: hidden)} · '
      '${dateLabel(leg.date)}',
      style: theme.textTheme.bodySmall,
    );
  }
}
