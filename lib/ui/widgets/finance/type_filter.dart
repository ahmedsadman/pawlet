import 'package:flutter/material.dart';

import '../../../models/finance/transaction.dart';
import '../../../theme/catppuccin_theme.dart';

/// Multi-select chips filtering transactions by type. An empty selection means
/// "all types".
class TypeFilter extends StatelessWidget {
  const TypeFilter({
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<TxType> selected;
  final ValueChanged<List<TxType>> onChanged;

  static const _options = [
    (TxType.expense, 'Expense'),
    (TxType.income, 'Income'),
    (TxType.transfer, 'Transfer'),
  ];

  Color _color(TxType type, BuildContext context) => switch (type) {
    TxType.income => AppTheme.income,
    TxType.expense => AppTheme.expense,
    TxType.transfer => Theme.of(context).colorScheme.outline,
  };

  void _toggle(TxType type) {
    final next = List<TxType>.from(selected);
    if (next.contains(type)) {
      next.remove(type);
    } else {
      next.add(type);
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        for (final (type, label) in _options)
          FilterChip(
            label: Text(label),
            selected: selected.contains(type),
            selectedColor: _color(type, context).withValues(alpha: 0.25),
            onSelected: (_) => _toggle(type),
          ),
      ],
    );
  }
}
