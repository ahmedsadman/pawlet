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
  Widget child = const Text('home'),
  Widget Function(Widget shell)? wrap,
}) async {
  _unlocked = NotifierProvider<_Unlocked, bool>(() => _Unlocked(unlocked));
  _settle = Completer<void>()..complete();
  final shell = Scaffold(body: PairingPromptListener(child: child));
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
        // Mirrors AuthGate: the lock screen is stacked over the shell.
        home: wrap != null
            ? wrap(shell)
            : lockOverlay
            ? Consumer(
                builder: (context, ref, _) => Stack(
                  children: [
                    shell,
                    if (!ref.watch(_unlocked))
                      const Positioned.fill(
                        child: Scaffold(body: Text('locked')),
                      ),
                  ],
                ),
              )
            : shell,
      ),
    ),
  );
  await _settleFrames(tester);
  return ProviderScope.containerOf(
    tester.element(find.byType(PairingPromptListener)),
  );
}

/// Lets the data load, the settle future resolve and the pill animate in.
Future<void> _settleFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _bump(ProviderContainer container, WidgetTester tester) async {
  container.read(dataRevisionProvider.notifier).bump();
  await _settleFrames(tester);
}

final _anyPrompt = find.textContaining('to review');

void main() {
  testWidgets('prompts once the list loads non-empty', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    expect(find.text('1 pairing to review'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
  });

  testWidgets('stays quiet when there is nothing to review', (tester) async {
    await _pump(tester, FakePairingStore(const []));
    expect(_anyPrompt, findsNothing);
  });

  testWidgets('hides after the prompt duration', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    await tester.pump(
      PairingPromptListener.promptDuration - const Duration(seconds: 1),
    );
    expect(find.text('1 pairing to review'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_anyPrompt, findsNothing);
  });

  testWidgets('prompts again only for a new suggestion', (tester) async {
    final store = FakePairingStore([transferSuggestion(1, 2)]);
    final container = await _pump(tester, store);
    await tester.pump(PairingPromptListener.promptDuration);
    await tester.pumpAndSettle();

    // Same list after a data change: no prompt.
    await _bump(container, tester);
    expect(_anyPrompt, findsNothing);

    // A new suggestion appears: prompt with the full count.
    store.items.add(cardSuggestion(3, 4));
    await _bump(container, tester);
    expect(find.text('2 pairings to review'), findsOneWidget);
  });

  testWidgets('a new suggestion while the pill is up updates it in place', (
    tester,
  ) async {
    final store = FakePairingStore([transferSuggestion(1, 2)]);
    final container = await _pump(tester, store);
    await tester.pump(const Duration(seconds: 3));

    store.items.add(cardSuggestion(3, 4));
    await _bump(container, tester);
    expect(find.text('1 pairing to review'), findsNothing);
    expect(find.text('2 pairings to review'), findsOneWidget);

    // The timer restarted: still up past the first prompt's deadline.
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('2 pairings to review'), findsOneWidget);
  });

  group('allowed', () {
    testWidgets('waits for unlock instead of prompting', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
        unlocked: false,
      );
      expect(_anyPrompt, findsNothing);

      container.read(_unlocked.notifier).set(true);
      await _settleFrames(tester);
      expect(find.text('1 pairing to review'), findsOneWidget);
    });

    testWidgets('hides at once when no longer allowed', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
      );
      expect(find.text('1 pairing to review'), findsOneWidget);

      container.read(_unlocked.notifier).set(false);
      await tester.pump();
      expect(_anyPrompt, findsNothing);
      expect(find.text('View'), findsNothing);
    });

    testWidgets('waits for the resume to settle before prompting', (
      tester,
    ) async {
      final store = FakePairingStore(const []);
      final container = await _pump(tester, store);

      _settle = Completer<void>();
      store.items.add(transferSuggestion(1, 2));
      await _bump(container, tester);
      expect(_anyPrompt, findsNothing);

      _settle.complete();
      await _settleFrames(tester);
      expect(find.text('1 pairing to review'), findsOneWidget);
    });

    testWidgets('a resume that re-locks keeps the suggestion for unlock', (
      tester,
    ) async {
      final store = FakePairingStore(const []);
      final container = await _pump(tester, store);

      _settle = Completer<void>();
      store.items.add(transferSuggestion(1, 2));
      await _bump(container, tester);
      container.read(_unlocked.notifier).set(false);
      _settle.complete();
      await _settleFrames(tester);
      expect(_anyPrompt, findsNothing);

      container.read(_unlocked.notifier).set(true);
      await _settleFrames(tester);
      expect(find.text('1 pairing to review'), findsOneWidget);
    });
  });

  group('review page', () {
    testWidgets('beginning a review hides the pill', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
      );
      expect(find.text('1 pairing to review'), findsOneWidget);

      container.read(pairingPromptTrackerProvider).beginReview();
      await tester.pumpAndSettle();
      expect(_anyPrompt, findsNothing);
    });

    testWidgets('opening the review page another way hides the pill', (
      tester,
    ) async {
      await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
      expect(find.text('1 pairing to review'), findsOneWidget);

      openPairingReview(tester.element(find.text('home')));
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsOneWidget);
      expect(_anyPrompt, findsNothing);
      expect(find.text('View'), findsNothing);
    });

    testWidgets('View opens the review deck', (tester) async {
      await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));

      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsOneWidget);
      expect(_anyPrompt, findsNothing);
    });

    testWidgets('tapping the pill opens the review deck', (tester) async {
      await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));

      await tester.tap(find.text('1 pairing to review'));
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsOneWidget);
    });

    testWidgets('closing the deck does not prompt about what it showed', (
      tester,
    ) async {
      final store = FakePairingStore([transferSuggestion(1, 2)]);
      final container = await _pump(tester, store);

      openPairingReview(tester.element(find.text('home')));
      await tester.pumpAndSettle();
      store.items.add(cardSuggestion(3, 4));
      await _bump(container, tester);
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.byType(PairingReviewPage))).pop();
      await _settleFrames(tester);
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsNothing);
      expect(_anyPrompt, findsNothing);
    });

    testWidgets('View waits for a resume to settle before opening', (
      tester,
    ) async {
      await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));

      _settle = Completer<void>();
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsNothing);
      expect(_anyPrompt, findsNothing);

      _settle.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsOneWidget);
    });

    testWidgets('View opens nothing if the resume re-locks', (tester) async {
      final container = await _pump(
        tester,
        FakePairingStore([transferSuggestion(1, 2)]),
      );

      _settle = Completer<void>();
      await tester.tap(find.text('View'));
      await tester.pump();
      container.read(_unlocked.notifier).set(false);
      _settle.complete();
      await tester.pumpAndSettle();
      expect(find.byType(PairingReviewPage), findsNothing);
    });
  });

  testWidgets('the lock screen covers the pill', (tester) async {
    final container = await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
      lockOverlay: true,
    );
    expect(find.text('View').hitTestable(), findsOneWidget);

    container.read(_unlocked.notifier).set(false);
    await tester.pump();
    expect(find.text('locked'), findsOneWidget);
    expect(find.text('View').hitTestable(), findsNothing);
    expect(find.text('1 pairing to review').hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('View'), findsNothing);
  });

  group('another route on top', () {
    Future<void> expectHeldUntilPopped(
      WidgetTester tester,
      void Function(BuildContext shell) cover,
    ) async {
      final store = FakePairingStore([transferSuggestion(1, 2)]);
      final container = await _pump(tester, store);
      await tester.pump(PairingPromptListener.promptDuration);
      await tester.pumpAndSettle();
      expect(_anyPrompt, findsNothing);

      final shell = tester.element(find.text('home'));
      cover(shell);
      await tester.pumpAndSettle();

      // A new suggestion arrives while the route is up: no pill under it.
      store.items.add(cardSuggestion(3, 4));
      await _bump(container, tester);
      await tester.pumpAndSettle();
      // Offstage too: a page route hides the shell once it has slid in.
      expect(
        find.textContaining('to review', skipOffstage: false),
        findsNothing,
      );
      expect(find.text('View').hitTestable(), findsNothing);
      // Long enough for a pill shown under the route to have timed out.
      await tester.pump(PairingPromptListener.promptDuration);
      await tester.pumpAndSettle();

      // Popped: the keys were left unseen, so the pill shows now.
      Navigator.of(shell).pop();
      await _settleFrames(tester);
      expect(find.text('2 pairings to review'), findsOneWidget);
      expect(find.text('View').hitTestable(), findsOneWidget);
    }

    testWidgets('a pushed page holds the pill until it closes', (tester) async {
      await expectHeldUntilPopped(tester, (shell) {
        Navigator.of(shell).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('page')),
          ),
        );
      });
    });

    testWidgets('a bottom sheet holds the pill until it closes', (
      tester,
    ) async {
      await expectHeldUntilPopped(tester, (shell) {
        showModalBottomSheet<void>(
          context: shell,
          builder: (_) => const SizedBox(height: 200, child: Text('sheet')),
        );
      });
    });

    testWidgets('a visible pill hides when a page is pushed over it', (
      tester,
    ) async {
      await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
      expect(find.text('1 pairing to review'), findsOneWidget);

      Navigator.of(tester.element(find.text('home'))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('page')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('page'), findsOneWidget);
      expect(_anyPrompt, findsNothing);

      // Shown once already: popping doesn't bring it back.
      Navigator.of(tester.element(find.text('page'))).pop();
      await tester.pumpAndSettle();
      expect(_anyPrompt, findsNothing);
    });
  });

  testWidgets('a full-screen overlay in the same route covers the pill', (
    tester,
  ) async {
    // The overlay alone, with the gate left open: coverage is structural.
    final covered = ValueNotifier(false);
    addTearDown(covered.dispose);
    await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
      wrap: (shell) => ValueListenableBuilder(
        valueListenable: covered,
        builder: (_, on, _) => Stack(
          children: [
            shell,
            if (on)
              const Positioned.fill(child: Scaffold(body: Text('locked'))),
          ],
        ),
      ),
    );
    expect(find.text('View').hitTestable(), findsOneWidget);

    covered.value = true;
    await tester.pump();
    expect(find.text('View').hitTestable(), findsNothing);
    expect(find.text('1 pairing to review').hitTestable(), findsNothing);
  });

  testWidgets('backgrounding the app hides the pill', (tester) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    expect(find.text('1 pairing to review'), findsOneWidget);

    // Leaving the foreground passes through inactive first; frames still run
    // there, so the pill is gone before the app is hidden.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(_anyPrompt, findsNothing);
  });

  testWidgets('a fading pill no longer takes taps', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    final view = tester.getCenter(find.text('View'));

    await tester.pump(PairingPromptListener.promptDuration);
    await tester.pump(const Duration(milliseconds: 50));
    // Still on screen, mid-fade.
    expect(find.text('View'), findsOneWidget);

    await tester.tapAt(view);
    await tester.pumpAndSettle();
    expect(find.byType(PairingReviewPage), findsNothing);
  });

  testWidgets('the pill does not block taps elsewhere', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2)]),
      child: Column(
        children: [
          const Text('home'),
          const Spacer(),
          // Under the pill's layer, beside its bottom edge.
          Align(
            alignment: Alignment.bottomLeft,
            child: TextButton(onPressed: () => taps++, child: const Text('x')),
          ),
        ],
      ),
    );
    expect(find.text('View').hitTestable(), findsOneWidget);

    await tester.tap(find.text('x'));
    expect(taps, 1);
  });
}
