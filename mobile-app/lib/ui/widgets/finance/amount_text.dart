import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/transaction.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';

/// A signed, color-coded monetary amount: `+` green for income, `−` red for
/// expense, and an unsigned muted value for transfers. When balances are hidden
/// the value is masked (`**** BDT`) with the sign dropped but the color kept.
class AmountText extends ConsumerWidget {
  const AmountText({
    required this.amount,
    required this.currency,
    required this.type,
    this.style,
    super.key,
  });

  final String amount;
  final String currency;
  final TxType type;
  final TextStyle? style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hidden = ref.watch(balanceHiddenProvider);
    final (sign, color) = switch (type) {
      TxType.income => ('+', AppTheme.income),
      TxType.expense => ('−', AppTheme.expense),
      TxType.transfer => ('', theme.colorScheme.outline),
    };
    final base = style ?? theme.textTheme.bodyLarge;
    return Text(
      hidden
          ? formatAmount(amount, currency, hidden: true)
          : '$sign${formatAmount(amount, currency)}',
      style: base?.copyWith(
        color: color,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
  }
}
