import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/finance_providers.dart';
import '../skeleton.dart';
import 'finance_placeholders.dart';

/// A transaction's backing SMS: sender above, full text below.
class BackingMessage extends ConsumerWidget {
  const BackingMessage({required this.id, super.key});

  final int id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(messageProvider(id));
    return async.when(
      loading: () => const MessageLinesSkeleton(),
      error: (_, _) => FinanceError(
        'Could not load the message.',
        onRetry: () => ref.invalidate(messageProvider(id)),
      ),
      data: (result) {
        final message = result.data;
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
      },
    );
  }
}
