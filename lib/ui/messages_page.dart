import 'package:flutter/material.dart';

/// Placeholder for the Messages tab. The queue + history UI (with search and
/// read-only labels) is built in a later phase; kept here so the bottom
/// navigation matches the final three-tab layout.
class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: Center(
        child: Text(
          'Coming soon',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
