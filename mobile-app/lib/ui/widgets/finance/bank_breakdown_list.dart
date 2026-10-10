import 'package:flutter/material.dart';

import '../../../models/finance/bank.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import '../../banks_page.dart';
import 'finance_badge.dart';

/// Per-bank breakdown revealed under the total-balance card. Deposit accounts
/// show their balance; credit cards show their masked number and are excluded
/// from the total.
class BankBreakdownList extends StatelessWidget {
  const BankBreakdownList({
    required this.banks,
    required this.currency,
    this.hidden = false,
    super.key,
  });

  final List<Bank> banks;
  final String currency;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (banks.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          'No accounts yet.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
    }

    return Column(
      children: [
        const Divider(height: 24),
        for (final bank in banks)
          _BankRow(bank: bank, currency: currency, hidden: hidden),
        // A subtle, non-primary entry point to bank management (a FilledButton
        // would read as a heavy CTA inside the balance card).
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const BanksPage())),
            icon: const Icon(Icons.account_balance_outlined, size: 18),
            label: const Text('Manage Banks & Cards'),
          ),
        ),
      ],
    );
  }
}

class _BankRow extends StatelessWidget {
  const _BankRow({
    required this.bank,
    required this.currency,
    required this.hidden,
  });

  final Bank bank;
  final String currency;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _BankAvatar(name: bank.name),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        bank.name,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (bank.isCredit) ...[
                      const SizedBox(width: 8),
                      FinanceBadge(
                        'Credit',
                        icon: Icons.credit_card,
                        color: AppTheme.flavor.peach,
                      ),
                    ],
                  ],
                ),
                if (bank.isCredit)
                  Text(
                    '•••• ${bank.last4 ?? '----'} · not counted',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.flavor.subtext0,
                    ),
                  )
                else if (bank.lastBalanceAt != null)
                  Text(
                    updatedLabel(bank.lastBalanceAt!),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppTheme.flavor.subtext0,
                    ),
                  ),
              ],
            ),
          ),
          if (bank.isDeposit)
            Text(
              bank.lastBalance != null
                  ? formatAmount(bank.lastBalance, currency, hidden: hidden)
                  : 'No balance yet',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

/// A 28px circle showing the bank's initial letter — a lightweight stand-in for
/// a logo (the model carries no logo).
class _BankAvatar extends StatelessWidget {
  const _BankAvatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initial = name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.flavor.surface1,
        shape: BoxShape.circle,
      ),
      child: Text(
        initial,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
