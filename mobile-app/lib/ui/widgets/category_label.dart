import 'package:flutter/material.dart';

import '../../models/finance/transaction.dart';
import '../../theme/catppuccin_theme.dart';

/// Read-only pill showing the classification label in the History list. Bills
/// read as "Bill"; transactions show their subcategory (Income / Expense /
/// Transfer) when [type] is known, otherwise the generic "Transaction". The
/// label reflects the pipeline's decision and is not editable.
class CategoryLabel extends StatelessWidget {
  const CategoryLabel(this.category, {this.type, super.key});

  /// `transaction` or `bill`.
  final String category;

  /// The backing transaction's type, when [category] is `transaction`. Null for
  /// bills or when the type wasn't joined in.
  final TxType? type;

  @override
  Widget build(BuildContext context) {
    final (color, label) = _display();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  (Color, String) _display() {
    if (category == 'bill') return (AppTheme.flavor.peach, 'Bill');
    return switch (type) {
      TxType.income => (AppTheme.income, 'Income'),
      TxType.expense => (AppTheme.expense, 'Expense'),
      TxType.transfer => (AppTheme.flavor.lavender, 'Transfer'),
      null => (AppTheme.flavor.blue, 'Transaction'),
    };
  }
}
