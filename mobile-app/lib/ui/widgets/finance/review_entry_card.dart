import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/pairing_providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../pairing_review_page.dart';

/// Top-of-page call to action while pairings await review. Takes no space
/// when there are none (or before they load).
class ReviewEntryCard extends ConsumerWidget {
  const ReviewEntryCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pairingSuggestionsProvider).value?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final f = AppTheme.flavor;
    final accent = f.peach;
    final radius = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: () => openPairingReview(context),
          child: Ink(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: accent.withValues(alpha: 0.35)),
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.16),
                  accent.withValues(alpha: 0.04),
                ],
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.swap_horiz, color: accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pairingCountLabel(count),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Transfers & card payments',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: f.subtext0,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: f.subtext0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
