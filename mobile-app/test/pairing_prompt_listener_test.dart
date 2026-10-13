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

Future<ProviderContainer> _pump(
  WidgetTester tester,
  FakePairingStore store, {
  bool unlocked = true,
}) async {
  _unlocked = NotifierProvider<_Unlocked, bool>(() => _Unlocked(unlocked));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(false),
        ...store.overrides,
        pairingPromptAllowedProvider.overrideWith(
          (ref) => ref.watch(_unlocked),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: PairingPromptListener(child: Text('home'))),
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
}
