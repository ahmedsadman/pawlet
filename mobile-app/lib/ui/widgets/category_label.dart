import 'package:flutter/material.dart';

import '../../theme/catppuccin_theme.dart';

/// Read-only pill showing the classification label (Transaction / Bill) in the
/// History list. The label reflects the pipeline's decision and is not editable.
class CategoryLabel extends StatelessWidget {
  const CategoryLabel(this.category, {super.key});

  /// `transaction` or `bill`.
  final String category;

  @override
  Widget build(BuildContext context) {
    final (color, label) = category == 'bill'
        ? (AppTheme.flavor.peach, 'Bill')
        : (AppTheme.flavor.blue, 'Transaction');

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
}
