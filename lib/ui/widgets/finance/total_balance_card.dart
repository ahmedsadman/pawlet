import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/time_format.dart';
import '../../banks_page.dart';
import 'bank_breakdown_list.dart';

/// Total deposit balance across accounts. Tapping toggles a per-bank breakdown
/// (hidden by default). When the user has no banks yet, the card becomes an
/// "Add Bank" call-to-action (Meowni's first-run entry point).
class TotalBalanceCard extends ConsumerStatefulWidget {
  const TotalBalanceCard({super.key});

  @override
  ConsumerState<TotalBalanceCard> createState() => _TotalBalanceCardState();
}

class _TotalBalanceCardState extends ConsumerState<TotalBalanceCard> {
  bool _expanded = false;

  static double _total(List<Bank> banks) => banks
      .where((b) => b.isDeposit && b.lastBalance != null)
      .fold(0.0, (sum, b) => sum + (double.tryParse(b.lastBalance!) ?? 0));

  /// Most-recent balance update across deposit accounts, or null if none.
  static DateTime? _lastUpdated(List<Bank> banks) {
    DateTime? latest;
    for (final b in banks) {
      final at = b.lastBalanceAt;
      if (b.isDeposit && at != null && (latest == null || at.isAfter(latest))) {
        latest = at;
      }
    }
    return latest;
  }

  Future<void> _addBank() async {
    final saved = await Navigator.of(
      context,
    ).push<bool>(MaterialPageRoute(builder: (_) => const BankFormPage()));
    if (!mounted || saved != true) return;
    refreshAllFinance(ref);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final banksAsync = ref.watch(banksProvider);
    final banks = banksAsync.value?.data;
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final hidden = ref.watch(balanceHiddenProvider);

    final hasBanks = banks != null && banks.isNotEmpty;

    // Loaded with no banks → first-run Add Bank call-to-action.
    if (banksAsync.hasValue && !hasBanks) {
      return _AddBankCta(theme: theme, onAdd: _addBank);
    }

    final totalLabel = hasBanks
        ? formatMoney(_total(banks), currency, hidden: hidden)
        : '—';
    final lastUpdated = hasBanks ? _lastUpdated(banks) : null;

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: hasBanks ? () => setState(() => _expanded = !_expanded) : null,
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
                              Icons.account_balance_wallet_outlined,
                              size: 16,
                              color: AppTheme.flavor.mauve,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'Total Balance',
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: AppTheme.flavor.subtext0,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          totalLabel,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (lastUpdated != null) ...[
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Icon(
                                Icons.schedule,
                                size: 12,
                                color: AppTheme.flavor.subtext0,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Updated ${relativeTime(lastUpdated.toLocal())}',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppTheme.flavor.subtext0,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (hasBanks)
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
              if (_expanded && hasBanks)
                BankBreakdownList(
                  banks: banks,
                  currency: currency,
                  hidden: hidden,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// First-run empty state: prompts the user to add their first bank. Reuses the
/// Card language so it is visually consistent with the populated card.
class _AddBankCta extends StatelessWidget {
  const _AddBankCta({required this.theme, required this.onAdd});

  final ThemeData theme;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 16,
                  color: AppTheme.flavor.mauve,
                ),
                const SizedBox(width: 6),
                Text(
                  'Total Balance',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: AppTheme.flavor.subtext0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Add a bank to get started',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Meowni reads your bank SMS on this device and records transactions '
              'and bills. Add a bank so it knows which senders to watch.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppTheme.flavor.subtext0,
              ),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add),
                label: const Text('Add Bank'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
