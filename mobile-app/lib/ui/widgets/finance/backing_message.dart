import 'package:flutter/material.dart';

import '../../../models/finance/sms_text.dart';

/// A transaction's or bill's backing SMS: sender above, full text below. The
/// text arrives with the row that owns it, so it renders at full size at once.
class BackingMessage extends StatelessWidget {
  const BackingMessage(this.message, {super.key});

  final SmsText message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message.sender,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
        const SizedBox(height: 2),
        Text(message.content, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
