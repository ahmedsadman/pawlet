import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/finance/pairing_suggestion.dart';
import '../services/finance/pairing_actions.dart';
import '../services/finance/pairing_suggester.dart';
import 'auth_providers.dart';
import 'providers.dart';

final pairingSuggesterProvider = Provider<PairingSuggester>(
  (ref) => PairingSuggester(ref.watch(databaseProvider)),
);

final pairingActionsProvider = Provider<PairingActions>(
  (ref) => PairingActions(ref.watch(databaseProvider)),
);

/// The pending pairing-review cards, newest first. Recomputed whenever local
/// data changes, including writes from background isolates.
final pairingSuggestionsProvider =
    FutureProvider.autoDispose<List<PairingSuggestion>>((ref) {
      ref.watch(dataRevisionProvider);
      return ref
          .watch(pairingSuggesterProvider)
          .suggest(nowMs: DateTime.now().millisecondsSinceEpoch);
    });

/// Whether the floating prompt may show now: never over the lock screen.
final pairingPromptAllowedProvider = Provider<bool>(
  (ref) => ref.watch(
    authControllerProvider.select((s) => s.status == AuthStatus.unlocked),
  ),
);

final pairingPromptTrackerProvider = Provider<PairingPromptTracker>(
  (ref) => PairingPromptTracker(),
);

/// Decides when the "N pairings to review" prompt shows: the first time the
/// list loads non-empty, then whenever a suggestion appears that this session
/// has not seen.
class PairingPromptTracker {
  final Set<String> _seen = {};

  /// True while the review page is open; new keys are absorbed silently so
  /// the user isn't prompted about the deck they are looking at.
  bool reviewing = false;

  /// Marks [keys] seen and returns whether any of them were new.
  bool shouldPrompt(Iterable<String> keys) {
    var fresh = false;
    for (final key in keys) {
      if (_seen.add(key)) fresh = true;
    }
    return fresh && !reviewing;
  }
}
