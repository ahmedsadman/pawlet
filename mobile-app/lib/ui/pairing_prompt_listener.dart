import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/pairing_providers.dart';
import '../theme/catppuccin_theme.dart';
import 'pairing_review_page.dart';

/// Shows a floating "N pairings to review" prompt the first time the review
/// list loads non-empty, and again whenever a suggestion appears that this
/// session hasn't seen. Silent while locked — the keys stay unseen, so the
/// prompt shows on unlock — and while the review page is open.
///
/// The lock screen is a sibling Scaffold of the app's, and the messenger shows
/// its snackbar on every Scaffold, so the prompt is taken down the moment the
/// app locks and never surfaces later from the queue. Opening a review page
/// takes it down too.
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
  late final PairingPromptTracker _tracker;

  /// The prompt this listener has up or queued, until it closes or is retired.
  _Prompt? _prompt;

  @override
  void initState() {
    super.initState();
    _tracker = ref.read(pairingPromptTrackerProvider);
    // The list may already be loaded (another widget watched it first), in
    // which case no change arrives for the listeners below.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _evaluate();
    });
  }

  @override
  void dispose() {
    // Nothing would take it down on lock any more.
    _dismiss();
    super.dispose();
  }

  Future<void> _evaluate() async {
    // Wait out a resume's re-lock decision first, and again if another resume
    // started meanwhile. Keys are only consumed after it, so a resume that
    // re-locks leaves them unseen for the prompt on unlock.
    final settled = ref.read(pairingPromptSettledProvider);
    Future<void> pending;
    do {
      pending = settled();
      await pending;
      if (!mounted) return;
    } while (!identical(pending, settled()));

    final suggestions = ref.read(pairingSuggestionsProvider).value;
    if (suggestions == null || !ref.read(pairingPromptAllowedProvider)) return;
    if (!_tracker.shouldPrompt(suggestions.map((s) => s.key))) return;
    // A prompt already up carries a stale count: replace it.
    _dismiss();
    _show(suggestions.length);
  }

  /// Takes down this listener's prompt, if any.
  void _dismiss() {
    final prompt = _prompt;
    if (prompt == null) return;
    _forget(prompt);
    prompt.retire();
  }

  void _forget(_Prompt prompt) {
    if (!identical(_prompt, prompt)) return;
    _prompt = null;
    if (_tracker.dismissPrompt == _dismiss) _tracker.dismissPrompt = null;
  }

  void _show(int count) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final prompt = _Prompt(messenger);
    prompt.controller = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.primaryContainer,
        duration: PairingPromptListener.promptDuration,
        // An action makes a snackbar persist by default, ignoring duration;
        // that would block every other snackbar in the app.
        persist: false,
        content: _PromptContent(
          prompt: prompt,
          child: Row(
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
        ),
        action: SnackBarAction(
          label: 'View',
          textColor: scheme.primary,
          onPressed: () {
            // Checked at tap time: the review page is pushed on the root
            // navigator, above the lock screen.
            if (!mounted || !ref.read(pairingPromptAllowedProvider)) return;
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const PairingReviewPage(),
              ),
            );
          },
        ),
      ),
    );
    _prompt = prompt;
    _tracker.dismissPrompt = _dismiss;
    prompt.controller.closed.then((_) {
      prompt.closed = true;
      _forget(prompt);
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pairingSuggestionsProvider, (_, _) => _evaluate());
    ref.listen(pairingPromptAllowedProvider, (_, allowed) {
      allowed ? _evaluate() : _dismiss();
    });
    return widget.child;
  }
}

/// One shown prompt.
///
/// The messenger only builds its current snackbar, so the content being
/// mounted means this prompt is on screen; until then it is queued behind
/// another snackbar. `controller.close()` can't be used to take it down: it
/// hides whichever snackbar is current, and asserts that it is this one.
class _Prompt {
  _Prompt(this.messenger);

  final ScaffoldMessengerState messenger;
  late final ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
  controller;

  /// Mounted copies of the content, one per Scaffold presenting it.
  int surfaced = 0;

  /// Taken down; if still queued, it removes itself when it surfaces.
  bool retired = false;

  /// Closed, or removal requested: it may no longer be the current snackbar.
  bool closed = false;

  void retire() {
    retired = true;
    removeIfSurfaced();
  }

  /// Removes the prompt at once, without the exit animation, so it doesn't
  /// linger on a lock screen that just came up.
  void removeIfSurfaced() {
    if (surfaced == 0 || closed) return;
    final scheduler = SchedulerBinding.instance;
    // Removing rebuilds the messenger, which can't happen mid-build (a review
    // page begins its review from initState).
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) => removeIfSurfaced());
      return;
    }
    closed = true;
    if (messenger.mounted) messenger.removeCurrentSnackBar();
  }
}

/// Tracks whether its prompt is on screen, and removes a retired prompt the
/// moment it surfaces from the queue.
///
/// Blank while retired or not allowed: a lock arrives mid-build, so removal
/// waits for the end of the frame, and the lock screen's first frame must not
/// show the count.
class _PromptContent extends ConsumerStatefulWidget {
  const _PromptContent({required this.prompt, required this.child});

  final _Prompt prompt;
  final Widget child;

  @override
  ConsumerState<_PromptContent> createState() => _PromptContentState();
}

class _PromptContentState extends ConsumerState<_PromptContent> {
  @override
  void initState() {
    super.initState();
    widget.prompt.surfaced++;
    if (widget.prompt.retired) widget.prompt.removeIfSurfaced();
  }

  @override
  void dispose() {
    widget.prompt.surfaced--;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allowed = ref.watch(pairingPromptAllowedProvider);
    return allowed && !widget.prompt.retired
        ? widget.child
        : const SizedBox.shrink();
  }
}
