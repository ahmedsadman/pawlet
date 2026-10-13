import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/pairing_providers.dart';
import '../theme/catppuccin_theme.dart';
import 'pairing_review_page.dart';

/// Shows a floating "N pairings to review" prompt the first time the review
/// list loads non-empty, and again whenever a suggestion appears that this
/// session hasn't seen. Silent while locked — the keys stay unseen, so the
/// prompt shows on unlock — and while the review page is open.
class PairingPromptListener extends ConsumerStatefulWidget {
  const PairingPromptListener({required this.child, super.key});

  final Widget child;

  /// How long the prompt shows before auto-hiding.
  static const promptDuration = Duration(seconds: 5);

  @override
  ConsumerState<PairingPromptListener> createState() =>
      _PairingPromptListenerState();
}

class _PairingPromptListenerState extends ConsumerState<PairingPromptListener> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    // The list may already be loaded (another widget watched it first), in
    // which case no change arrives for the listeners below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _evaluate();
    });
  }

  void _evaluate() {
    final suggestions = ref.read(pairingSuggestionsProvider).value;
    if (suggestions == null || !ref.read(pairingPromptAllowedProvider)) return;
    final tracker = ref.read(pairingPromptTrackerProvider);
    if (!tracker.shouldPrompt(suggestions.map((s) => s.key))) return;
    if (_showing) return;
    _show(suggestions.length);
  }

  void _show(int count) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    _showing = true;
    final controller = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.primaryContainer,
        duration: PairingPromptListener.promptDuration,
        // An action makes a snackbar persist by default, ignoring duration;
        // that would block every other snackbar in the app.
        persist: false,
        content: Row(
          children: [
            Icon(Icons.swap_horiz, color: AppTheme.flavor.peach),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                pairingCountLabel(count),
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'View',
          textColor: scheme.primary,
          onPressed: () => navigator.push(
            MaterialPageRoute<void>(builder: (_) => const PairingReviewPage()),
          ),
        ),
      ),
    );
    controller.closed.then((_) => _showing = false);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pairingSuggestionsProvider, (_, _) => _evaluate());
    ref.listen(pairingPromptAllowedProvider, (_, allowed) {
      if (allowed) _evaluate();
    });
    return widget.child;
  }
}
