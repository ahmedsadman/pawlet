import 'package:flutter/material.dart';

import '../../models/sms_record.dart';
import '../../theme/catppuccin_theme.dart';

/// Small colored pill showing an SMS processing status (used in the Queue).
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final SmsStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      SmsStatus.queued => (AppTheme.flavor.peach, 'Queued'),
      SmsStatus.sending => (AppTheme.flavor.blue, 'Processing'),
      SmsStatus.success => (AppTheme.flavor.green, 'Done'),
      // Ignored rows are never rendered (not in Queue or History); this case
      // only keeps the switch exhaustive.
      SmsStatus.ignored => (AppTheme.flavor.overlay0, 'Ignored'),
      SmsStatus.failure => (AppTheme.flavor.red, 'Failed'),
    };

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
