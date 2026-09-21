import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../models/finance/bill.dart';
import '../../../state/finance_providers.dart';
import '../section_header.dart';
import '../skeleton.dart';
import 'bill_row.dart';

/// Per credit-card bills. Each card shows its latest bill by default; tapping
/// the card header reveals previous bills. Hidden entirely when the user has no
/// credit cards.
class CreditCardBillsSection extends ConsumerWidget {
  const CreditCardBillsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banksAsync = ref.watch(banksProvider);
    final banks = banksAsync.value?.data;
    if (banks == null) {
      // Reserve the section with a skeleton while banks load so it doesn't pop
      // in and shove the rest of the page down when data arrives.
      return banksAsync.isLoading
          ? const CreditCardBillsSkeleton()
          : const SizedBox.shrink();
    }
    final creditCards = banks.where((b) => b.isCredit).toList();
    if (creditCards.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Credit Card Bills'),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < creditCards.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _BankBills(bank: creditCards[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BankBills extends ConsumerStatefulWidget {
  const _BankBills({required this.bank});

  final Bank bank;

  @override
  ConsumerState<_BankBills> createState() => _BankBillsState();
}

class _BankBillsState extends ConsumerState<_BankBills> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final async = ref.watch(billsProvider(widget.bank.id));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: async.when(
        loading: () =>
            _header(theme, trailing: const Skeleton(width: 56, height: 12)),
        error: (_, _) => _header(theme, subtitle: 'Could not load bills.'),
        data: (result) {
          final bills = [...result.data.bills]
            ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
          if (bills.isEmpty) {
            return _header(theme, subtitle: 'No bills yet.');
          }
          final rest = bills.skip(1).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: rest.isEmpty
                    ? null
                    : () => setState(() => _expanded = !_expanded),
                child: _header(
                  theme,
                  trailing: rest.isEmpty
                      ? null
                      : AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                ),
              ),
              BillRow(bill: bills.first, currency: currency),
              if (_expanded)
                for (final Bill bill in rest)
                  BillRow(bill: bill, currency: currency),
            ],
          );
        },
      ),
    );
  }

  Widget _header(ThemeData theme, {Widget? trailing, String? subtitle}) {
    return Row(
      children: [
        Icon(Icons.receipt_long_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.bank.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
