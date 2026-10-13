import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/pairing_providers.dart';
import '../theme/catppuccin_theme.dart';
import 'pairing_review_page.dart';

/// Floats an "N pairings to review" pill over [child] the first time the
/// review list loads non-empty, and again whenever a suggestion appears that
/// this session hasn't seen. Silent while locked — the keys stay unseen, so
/// the pill shows on unlock — and while the review page is open.
///
/// The pill lives in this widget's own subtree, so the lock screen and any
/// pushed route cover it: it can never surface above either.
class PairingPromptListener extends ConsumerStatefulWidget {
  const PairingPromptListener({required this.child, super.key});

  final Widget child;

  /// How long the pill shows before auto-hiding.
  static const promptDuration = Duration(seconds: 5);

  @override
  ConsumerState<PairingPromptListener> createState() =>
      _PairingPromptListenerState();
}

class _PairingPromptListenerState extends ConsumerState<PairingPromptListener> {
  late final PairingPromptTracker _tracker;

  /// The count on the pill; null while hidden.
  int? _count;
  Timer? _hideTimer;

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
    _hideTimer?.cancel();
    if (_tracker.dismissPrompt == _hide) _tracker.dismissPrompt = null;
    super.dispose();
  }

  Future<void> _evaluate() async {
    // Wait out a resume's re-lock decision first, and again if another resume
    // started meanwhile. Keys are only consumed after it, so a resume that
    // re-locks leaves them unseen for the pill on unlock.
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
    _hideTimer?.cancel();
    _hideTimer = Timer(PairingPromptListener.promptDuration, _hide);
    _tracker.dismissPrompt = _hide;
    _setCount(suggestions.length);
  }

  void _hide() {
    _hideTimer?.cancel();
    if (_tracker.dismissPrompt == _hide) _tracker.dismissPrompt = null;
    if (_count != null) _setCount(null);
  }

  void _setCount(int? count) {
    _count = count;
    final scheduler = SchedulerBinding.instance;
    // A review page begins its review from initState, mid-build; it covers
    // the pill meanwhile.
    if (scheduler.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      scheduler.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  void _open() {
    _hide();
    if (!mounted || !ref.read(pairingPromptAllowedProvider)) return;
    openPairingReview(context);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pairingSuggestionsProvider, (_, _) => _evaluate());
    ref.listen(pairingPromptAllowedProvider, (_, allowed) {
      allowed ? _evaluate() : _hide();
    });
    final allowed = ref.watch(pairingPromptAllowedProvider);
    final count = _count;
    return Stack(
      // Fill the body, so the pill's offsets are from its bottom edge.
      fit: StackFit.expand,
      children: [
        widget.child,
        if (allowed)
          // Above the Finance tab's FAB (56 px, 16 px margin).
          Positioned(
            left: 16,
            right: 16,
            bottom: 88,
            child: SafeArea(
              top: false,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween(
                      begin: const Offset(0, 0.5),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: count == null
                    ? const SizedBox.shrink()
                    : _Pill(
                        key: const ValueKey('pairing-pill'),
                        count: count,
                        onOpen: _open,
                      ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.count, required this.onOpen, super.key});

  final int count;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accent = AppTheme.flavor.peach;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: scheme.primaryContainer,
        elevation: 6,
        shadowColor: AppTheme.flavor.crust,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.swap_horiz, color: accent, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    pairingCountLabel(count),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onOpen,
                  style: TextButton.styleFrom(foregroundColor: scheme.primary),
                  child: const Text('View'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
