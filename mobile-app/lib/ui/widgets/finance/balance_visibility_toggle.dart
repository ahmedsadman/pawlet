import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../state/providers.dart';

/// A labelled divider under the Trends card that reveals or re-hides the
/// Total Balance and Trends amounts above it. It also marks where the masked
/// cards end: everything below always shows real values.
class BalanceVisibilityToggle extends ConsumerWidget {
  const BalanceVisibilityToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(balanceHiddenProvider);
    return Row(
      children: [
        const Expanded(child: Divider(indent: 4, endIndent: 8)),
        TextButton.icon(
          onPressed: () => ref.read(balanceHiddenProvider.notifier).toggle(),
          icon: Icon(
            hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
            size: 18,
          ),
          label: Text(hidden ? 'Show balances' : 'Hide balances'),
        ),
        const Expanded(child: Divider(indent: 8, endIndent: 4)),
      ],
    );
  }
}
