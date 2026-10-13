import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/finance/pairing_suggestion.dart';
import '../services/finance/pairing_actions.dart';
import '../state/pairing_providers.dart';
import '../state/providers.dart';
import '../theme/catppuccin_theme.dart';
import 'widgets/finance/finance_placeholders.dart';
import 'widgets/finance/pairing_card.dart';

/// `1 pairing to review` / `3 pairings to review`.
String pairingCountLabel(int count) =>
    count == 1 ? '1 pairing to review' : '$count pairings to review';

Future<void> openPairingReview(BuildContext context) => Navigator.of(
  context,
).push(MaterialPageRoute<void>(builder: (_) => const PairingReviewPage()));

/// One-at-a-time deck of pairing suggestions. Answer with the buttons or by
/// swiping (right = Yes, left = No); each answer can be undone from the
/// snackbar. Closes itself once nothing is left.
class PairingReviewPage extends ConsumerStatefulWidget {
  const PairingReviewPage({super.key});

  /// How long "All caught up" shows before the page closes.
  static const doneDelay = Duration(milliseconds: 1200);

  @override
  ConsumerState<PairingReviewPage> createState() => _PairingReviewPageState();
}

class _PairingReviewPageState extends ConsumerState<PairingReviewPage> {
  late final PairingPromptTracker _tracker;

  /// Answered this visit; drives the counter and the progress bar.
  int _answered = 0;

  /// Answered cards, hidden at once instead of waiting for the recompute.
  final Set<String> _hidden = {};

  /// A card brought back by Undo, shown on top of the deck.
  String? _pinned;

  Timer? _closeTimer;

  @override
  void initState() {
    super.initState();
    _tracker = ref.read(pairingPromptTrackerProvider)..beginReview();
  }

  @override
  void dispose() {
    _tracker.endReview();
    _closeTimer?.cancel();
    super.dispose();
  }

  List<PairingSuggestion> _deck(List<PairingSuggestion> all) {
    final deck = [
      for (final s in all)
        if (!_hidden.contains(s.key)) s,
    ];
    final i = deck.indexWhere((s) => s.key == _pinned);
    if (i > 0) deck.insert(0, deck.removeAt(i));
    return deck;
  }

  Future<void> _answer(PairingSuggestion s, bool yes) async {
    // A swipe and a button tap can both land before the rebuild.
    if (_hidden.contains(s.key)) return;
    final actions = ref.read(pairingActionsProvider);
    final revision = ref.read(dataRevisionProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _hidden.add(s.key);
      _answered++;
      if (_pinned == s.key) _pinned = null;
    });

    final PairingDecision? result;
    try {
      result = yes ? await actions.accept(s) : await actions.reject(s);
    } catch (_) {
      if (mounted) {
        setState(() {
          _hidden.remove(s.key);
          _answered--;
          // It was the top card; keep it there.
          _pinned = s.key;
        });
      }
      _showError(messenger, "Couldn't save that answer. Try again.");
      return;
    }
    revision.bump();
    // Null: a leg was settled elsewhere meanwhile; the card is gone anyway.
    final decision = result;
    if (decision == null) return;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
          // An action makes a snackbar persist by default, ignoring duration.
          persist: false,
          content: Text(yes ? 'Paired' : 'Marked as not a pair'),
          action: SnackBarAction(
            label: 'Undo',
            // May run after the page closed: only captured values below.
            onPressed: () async {
              try {
                await actions.undo(decision);
              } catch (_) {
                _showError(messenger, "Couldn't undo. Try again.");
                return;
              }
              revision.bump();
              if (!mounted) return;
              setState(() {
                _hidden.remove(s.key);
                _answered--;
                _pinned = s.key;
              });
            },
          ),
        ),
      );
  }

  void _showError(ScaffoldMessengerState messenger, String message) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
      );
  }

  void _scheduleClose(bool done) {
    if (!done) {
      _closeTimer?.cancel();
      _closeTimer = null;
      return;
    }
    _closeTimer ??= Timer(PairingReviewPage.doneDelay, () {
      _closeTimer = null;
      // Don't pop whatever was pushed on top of this page.
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = AppTheme.flavor;
    final async = ref.watch(pairingSuggestionsProvider);
    final all = async.value;
    final deck = all == null ? null : _deck(all);
    final total = _answered + (deck?.length ?? 0);
    if (deck != null) _scheduleClose(deck.isEmpty);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: [
          if (deck != null && deck.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Text(
                  '${_answered + 1} of $total',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: f.subtext0,
                  ),
                ),
              ),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: LinearProgressIndicator(
            // Empty until loaded; full only for "All caught up".
            value: deck == null
                ? 0
                : total == 0
                ? 1
                : _answered / total,
            minHeight: 3,
            color: f.mauve,
            backgroundColor: f.surface0,
          ),
        ),
      ),
      body: switch (deck) {
        null when async.hasError => Padding(
          padding: const EdgeInsets.all(16),
          child: FinanceError(
            'Could not load the review.',
            onRetry: () => ref.invalidate(pairingSuggestionsProvider),
          ),
        ),
        null => const Center(child: CircularProgressIndicator()),
        [] => const _AllCaughtUp(),
        [final top, ...] => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Only the incoming card animates. The outgoing one is either
              // swiped away by its Dismissible or removed at once; keeping it
              // around for an exit transition would leave a dismissed
              // Dismissible in the tree, which Flutter rejects.
              TweenAnimationBuilder<double>(
                key: ValueKey('enter-${top.key}'),
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                builder: (context, t, child) => Opacity(
                  opacity: t,
                  child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
                ),
                child: Dismissible(
                  key: ValueKey(top.key),
                  background: const _SwipeHint(yes: true),
                  secondaryBackground: const _SwipeHint(yes: false),
                  onDismissed: (direction) =>
                      _answer(top, direction == DismissDirection.startToEnd),
                  child: PairingCard(
                    key: ValueKey('card-${top.key}'),
                    suggestion: top,
                    onAnswer: (yes) => _answer(top, yes),
                  ),
                ),
              ),
              if (deck.length > 1) const _DeckEdge(inset: 12, alpha: 0.6),
              if (deck.length > 2) const _DeckEdge(inset: 24, alpha: 0.3),
              const SizedBox(height: 16),
              Text(
                'Swipe right for yes, left for no',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: f.overlay0),
              ),
            ],
          ),
        ),
      },
    );
  }
}

/// The edge of a card waiting underneath the top one.
class _DeckEdge extends StatelessWidget {
  const _DeckEdge({required this.inset, required this.alpha});

  final double inset;
  final double alpha;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 8,
      margin: EdgeInsets.symmetric(horizontal: inset),
      decoration: BoxDecoration(
        color: AppTheme.flavor.surface0.withValues(alpha: alpha),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      ),
    );
  }
}

/// Revealed behind a card while it is swiped.
class _SwipeHint extends StatelessWidget {
  const _SwipeHint({required this.yes});

  final bool yes;

  @override
  Widget build(BuildContext context) {
    final color = yes ? AppTheme.income : AppTheme.expense;
    return Container(
      alignment: yes ? Alignment.centerLeft : Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Icon(
        yes ? Icons.check_rounded : Icons.close_rounded,
        color: color,
        size: 32,
      ),
    );
  }
}

class _AllCaughtUp extends StatelessWidget {
  const _AllCaughtUp();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, size: 56, color: AppTheme.income),
          const SizedBox(height: 12),
          Text('All caught up', style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}
