import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/pairing_suggestion.dart';
import 'package:pawlet/services/finance/pairing_actions.dart';
import 'package:pawlet/state/pairing_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/pairing_review_page.dart';
import 'package:pawlet/ui/widgets/finance/pairing_card.dart';

import 'support/balance_test_overrides.dart';
import 'support/pairing_fakes.dart';

/// Fails every accept.
class _FailingAcceptStore extends FakePairingStore {
  _FailingAcceptStore(super.initial);

  @override
  Future<PairingDecision?> accept(PairingSuggestion s) async =>
      throw StateError('write failed');
}

/// Undo puts the suggestion back at the end, not the front.
class _UndoAppendsStore extends FakePairingStore {
  _UndoAppendsStore(super.initial);

  @override
  Future<void> undo(PairingDecision d) async {
    items.add(d.suggestion);
    (d.accepted ? accepted : rejected).remove(d.suggestion.key);
  }
}

/// Suggestions arrive only once [loaded] completes.
class _SlowStore extends FakePairingStore {
  _SlowStore(super.initial);

  final loaded = Completer<void>();

  @override
  Future<List<PairingSuggestion>> suggest({required int nowMs}) async {
    await loaded.future;
    return super.suggest(nowMs: nowMs);
  }
}

Future<T> _pump<T extends FakePairingStore>(
  WidgetTester tester,
  T store, {
  bool settle = true,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [overrideBalanceHidden(false), ...store.overrides],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => openPairingReview(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }
  return store;
}

void main() {
  testWidgets('shows the newest card first with a counter', (tester) async {
    await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    expect(find.text('Review'), findsOneWidget);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.byType(PairingCard), findsOneWidget);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
  });

  testWidgets('Yes accepts, advances and offers Undo', (tester) async {
    final store = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    await tester.tap(find.text('Yes, pair'));
    await tester.pumpAndSettle();

    expect(store.accepted, ['1-2']);
    expect(find.text('2 of 2'), findsOneWidget);
    expect(find.text('Did this pay your card?'), findsOneWidget);
    expect(find.text('Paired'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(store.accepted, isEmpty);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
  });

  testWidgets('swiping left rejects', (tester) async {
    final store = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    await tester.fling(find.byType(PairingCard), const Offset(-600, 0), 1500);
    await tester.pumpAndSettle();

    expect(store.rejected, ['1-2']);
    expect(find.text('Marked as not a pair'), findsOneWidget);
    expect(find.text('Did this pay your card?'), findsOneWidget);
  });

  testWidgets('swiping right accepts', (tester) async {
    final store = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
    );

    await tester.fling(find.byType(PairingCard), const Offset(600, 0), 1500);
    // Dismissible reports the swipe only after its move and resize animations.
    await tester.pumpAndSettle();

    expect(store.accepted, ['1-2']);
  });

  testWidgets('the last answer shows All caught up, then closes', (
    tester,
  ) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));

    await tester.tap(find.text('No'));
    await tester.pump();
    await tester.pump();

    expect(find.text('All caught up'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(find.text('All caught up'), findsNothing);
  });

  testWidgets('a failed save keeps the card and says so', (tester) async {
    final store = await _pump(
      tester,
      _FailingAcceptStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    await tester.tap(find.text('Yes, pair'));
    await tester.pump();
    await tester.pump();

    expect(store.accepted, isEmpty);
    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
    expect(find.text("Couldn't save that answer. Try again."), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
  });

  testWidgets('Undo on All caught up cancels the close', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));

    await tester.tap(find.text('No'));
    await tester.pump();
    await tester.pump();
    expect(find.text('All caught up'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Undo'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pumpAndSettle();

    expect(find.text('open'), findsNothing);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
    expect(find.text('1 of 1'), findsOneWidget);
  });

  testWidgets('Undo puts the card back on top wherever it reappears', (
    tester,
  ) async {
    await _pump(
      tester,
      _UndoAppendsStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    await tester.tap(find.text('Yes, pair'));
    await tester.pumpAndSettle();
    expect(find.text('Did this pay your card?'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('1 of 2'), findsOneWidget);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
  });

  testWidgets('the progress bar is empty while loading', (tester) async {
    final store = await _pump(
      tester,
      _SlowStore([transferSuggestion(1, 2)]),
      settle: false,
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0,
    );

    store.loaded.complete();
    await tester.pumpAndSettle();
    expect(find.text('1 of 1'), findsOneWidget);
  });

  testWidgets('the page marks the tracker reviewing while open', (
    tester,
  ) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    final tracker = ProviderScope.containerOf(
      tester.element(find.byType(PairingReviewPage)),
    ).read(pairingPromptTrackerProvider);

    expect(tracker.reviewing, isTrue);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('open'), findsOneWidget);
    expect(tracker.reviewing, isFalse);
  });
}
