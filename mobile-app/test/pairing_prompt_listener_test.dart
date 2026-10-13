import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/state/pairing_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/pairing_prompt_listener.dart';
import 'package:pawlet/ui/pairing_review_page.dart';

import 'support/balance_test_overrides.dart';
import 'support/pairing_fakes.dart';

class _Unlocked extends Notifier<bool> {
  _Unlocked(this.initial);
  final bool initial;
  @override
  bool build() => initial;
  void set(bool value) => state = value;
}

late NotifierProvider<_Unlocked, bool> _unlocked;

/// What the listener waits on before prompting; a pending completer stands
/// in for a resume whose re-lock decision hasn't arrived yet.
late Completer<void> _settle;

Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakePairingStore store, {
  bool unlocked = true,
  bool lockOverlay = false,
}) async {
  _unlocked = NotifierProvider<_Unlocked, bool>(() => _Unlocked(unlocked));
  _settle = Completer<void>()..complete();
  const shell = Scaffold(body: PairingPromptListener(child: Text('home')));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(false),
        ...store.overrides,
        pairingPromptAllowedProvider.overrideWith(
          (ref) => ref.watch(_unlocked),
        ),
        pairingPromptSettledProvider.overrideWithValue(() => _settle.future),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        // Mirrors AuthGate: the lock screen is a sibling Scaffold stacked over
        // the shell, so the messenger presents snackbars on it too.
        home: lockOverlay
            ? Consumer(
                builder: (context, ref, _) => Stack(
                  children: [
                    shell,
                    if (!ref.watch(_unlocked))
                      const Scaffold(body: Text('locked')),
                  ],
                ),
              )
            : shell,
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.text('home')));
}

Future<void> _waitPromptGone(WidgetTester tester) async {
  // Finish the entrance animation first: the messenger only starts the
  // auto-hide timer once the snackbar is fully shown.
  await tester.pumpAndSettle();
  await tester.pump(PairingPromptListener.promptDuration);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('prompts once the list loads non-empty', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
  });

  testWidgets('stays quiet when there is nothing to review', (tester) async {
    await _pump(tester, FakePairingStore(const []));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('to review'), findsNothing);
  });

  testWidgets('prompts again only for a new suggestion', (tester) async {
    final store = FakePairingStore([transferSuggestion(1, 2)]);
    final container = await _pump(tester, store);
    await _waitPromptGone(tester);

    // Same list after a data change: no prompt.
    container.read(dataRevisionProvider.notifier).bump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('to review'), findsNothing);

    // A new suggestion appears: prompt with the full count.
    store.items.add(cardSuggestion(3, 4));
    container.read(dataRevisionProvider.notifier).bump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('2 pairings to review'), findsOneWidget);
  });

  testWidgets('waits for unlock instead of prompting over the lock', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
      unlocked: false,
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('to review'), findsNothing);

    container.read(_unlocked.notifier).set(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsOneWidget);
  });

  testWidgets('View opens the review deck', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.text('View'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingReviewPage), findsOneWidget);
  });

  group('lock screen', () {
    testWidgets('locking takes the prompt off the lock screen', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
        lockOverlay: true,
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('1 pairing to review'), findsOneWidget);

      container.read(_unlocked.notifier).set(false);
      // The lock screen's first frame: the prompt may still be in the tree
      // until the frame ends, but must not show the count.
      await tester.pump();
      expect(find.text('locked'), findsOneWidget);
      expect(find.text('1 pairing to review'), findsNothing);
      await tester.pump();
      expect(find.text('View'), findsNothing);
      expect(find.text('1 pairing to review'), findsNothing);
    });

    testWidgets('a queued prompt never surfaces on the lock screen', (
      tester,
    ) async {
      final store = FakePairingStore(const []);
      final container = await _pump(tester, store, lockOverlay: true);
      // Another snackbar is up, so the prompt queues behind it.
      ScaffoldMessenger.of(
        tester.element(find.text('home')),
      ).showSnackBar(const SnackBar(content: Text('other')));
      store.items.add(transferSuggestion(1, 2));
      container.read(dataRevisionProvider.notifier).bump();
      await tester.pump();
      await tester.pump();
      expect(find.text('other'), findsOneWidget);

      container.read(_unlocked.notifier).set(false);
      await tester.pump();
      // Let the other snackbar time out; the queued prompt comes next.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('other'), findsNothing);
      expect(find.text('1 pairing to review'), findsNothing);
      expect(find.text('View'), findsNothing);
    });

    testWidgets('View does nothing once the app is locked', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
        lockOverlay: true,
      );
      await tester.pump(const Duration(milliseconds: 500));
      final action = tester.widget<SnackBarAction>(find.byType(SnackBarAction));

      container.read(_unlocked.notifier).set(false);
      await tester.pump();
      action.onPressed();
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsNothing);
    });

    testWidgets('waits for the resume to settle before prompting', (
      tester,
    ) async {
      final store = FakePairingStore(const []);
      final container = await _pump(tester, store);

      _settle = Completer<void>();
      store.items.add(transferSuggestion(1, 2));
      container.read(dataRevisionProvider.notifier).bump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('to review'), findsNothing);

      _settle.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('1 pairing to review'), findsOneWidget);
    });

    testWidgets('a resume that re-locks keeps the suggestion for unlock', (
      tester,
    ) async {
      final store = FakePairingStore(const []);
      final container = await _pump(tester, store, lockOverlay: true);

      _settle = Completer<void>();
      store.items.add(transferSuggestion(1, 2));
      container.read(dataRevisionProvider.notifier).bump();
      await tester.pump();
      container.read(_unlocked.notifier).set(false);
      _settle.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.textContaining('to review'), findsNothing);

      container.read(_unlocked.notifier).set(true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('1 pairing to review'), findsOneWidget);
    });
  });

  testWidgets('a new suggestion while the prompt is up updates the count', (
    tester,
  ) async {
    final store = FakePairingStore([transferSuggestion(1, 2)]);
    final container = await _pump(tester, store);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsOneWidget);

    store.items.add(cardSuggestion(3, 4));
    container.read(dataRevisionProvider.notifier).bump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsNothing);
    expect(find.text('2 pairings to review'), findsOneWidget);
  });

  testWidgets('beginning a review dismisses the prompt', (tester) async {
    final container = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsOneWidget);

    container.read(pairingPromptTrackerProvider).beginReview();
    await tester.pumpAndSettle();
    expect(find.text('1 pairing to review'), findsNothing);
  });

  testWidgets('opening the review page another way dismisses the prompt', (
    tester,
  ) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('1 pairing to review'), findsOneWidget);

    Navigator.of(
      tester.element(find.text('home')),
    ).push(MaterialPageRoute<void>(builder: (_) => const PairingReviewPage()));
    await tester.pumpAndSettle();
    expect(find.byType(PairingReviewPage), findsOneWidget);
    expect(find.text('1 pairing to review'), findsNothing);
    expect(find.text('View'), findsNothing);
  });
}
