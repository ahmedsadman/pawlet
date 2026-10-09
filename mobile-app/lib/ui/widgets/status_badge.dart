import 'package:flutter/material.dart';

import '../../models/sms_record.dart';
import '../../theme/catppuccin_theme.dart';

/// Small colored pill showing an SMS processing status (Queue rows, and
/// failed or ignored History rows).
class StatusBadge extends StatelessWidget {
  const StatusBadge(this.status, {super.key});

  final SmsStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (status) {
      SmsStatus.queued => (AppTheme.flavor.peach, 'Queued'),
      // Both in-flight states read the same to the user; the split between
      // on-device work and an LLM call is an internal scheduling concern.
      SmsStatus.processing ||
      SmsStatus.sending => (AppTheme.flavor.blue, 'Processing'),
      SmsStatus.success => (AppTheme.flavor.green, 'Done'),
      // Ignored bank messages appear in History (gated ones never do).
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
