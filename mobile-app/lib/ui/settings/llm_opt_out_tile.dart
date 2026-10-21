import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../widgets/sheet_parts.dart';

/// Settings tile that lets proxy users turn off the LLM. Shown only when
/// [mode.usesProxySession], so it stays visible after turning off (the mode
/// becomes [LlmMode.optedOut]).
///
/// Turning off asks first via [confirmLlmOptOut]; only "Turn off" flips it.
/// Turning on goes immediate with no sheet.
class LlmOptOutTile extends ConsumerWidget {
  const LlmOptOutTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(llmEnabledProvider);
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Use LLM for unknown messages'),
      subtitle: const Text(
        "When the on-device model can't classify a message, its text is sent "
        "to Pawlet's AI service to be categorized. Recommended.",
      ),
      value: enabled,
      onChanged: (value) async {
        if (value) {
          // Turning on: immediate, no confirmation needed.
          await ref.read(llmEnabledProvider.notifier).set(true);
        } else {
          // Turning off: ask first.
          if (!context.mounted) return;
          if (await confirmLlmOptOut(context)) {
            await ref.read(llmEnabledProvider.notifier).set(false);
          }
        }
      },
    );
  }
}

/// The opt-out warning sheet. Resolves true only when the user taps "Turn off";
/// "Keep on", drag-dismiss, back, and tap-outside all resolve false.
Future<bool> confirmLlmOptOut(BuildContext context) async {
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => const _LlmOptOutSheet(),
  );
  return accepted == true;
}

class _LlmOptOutSheet extends StatelessWidget {
  const _LlmOptOutSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SheetBody(
      children: [
        const SheetIcon(Icons.warning_amber_rounded),
        const SizedBox(height: 16),
        Text(
          'Turn off LLM?',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          "Messages the on-device model can't classify will be marked failed "
          'instead of categorized. You may miss transactions, bills and '
          'balance updates, so your Finance totals can be incomplete. '
          'Not recommended.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.outline,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep on'),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn off'),
          ),
        ),
      ],
    );
  }
}
