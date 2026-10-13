import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/pairing_review_page.dart';
import 'package:pawlet/ui/widgets/finance/pairing_card.dart';

import 'support/balance_test_overrides.dart';
import 'support/pairing_fakes.dart';

Future<FakePairingStore> _pump(
  WidgetTester tester,
  FakePairingStore store,
) async {
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
  await tester.pumpAndSettle();
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
}
