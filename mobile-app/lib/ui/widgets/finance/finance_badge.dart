import 'package:flutter/material.dart';

/// A small rounded pill for labels (bank name, "Credit", "Paid"/"Due", sender).
/// Mirrors the SMS status-badge styling for a consistent look.
class FinanceBadge extends StatelessWidget {
  const FinanceBadge(this.label, {this.color, this.icon, super.key});

  final String label;

  /// Tint for the pill; defaults to the muted outline color.
  final Color? color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tint),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              color: tint,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
