import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/pairing_review_page.dart';
import 'package:pawlet/ui/widgets/finance/review_entry_card.dart';

import 'support/balance_test_overrides.dart';
import 'support/pairing_fakes.dart';

Future<void> _pump(WidgetTester tester, FakePairingStore store) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [overrideBalanceHidden(false), ...store.overrides],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: ReviewEntryCard()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('hidden when nothing awaits review', (tester) async {
    await _pump(tester, FakePairingStore(const []));
    expect(find.textContaining('to review'), findsNothing);
  });

  testWidgets('shows the count and opens the review deck', (tester) async {
    await _pump(
      tester,
      FakePairingStore([transferSuggestion(1, 2), cardSuggestion(3, 4)]),
    );

    expect(find.text('2 pairings to review'), findsOneWidget);
    expect(find.text('Transfers & card payments'), findsOneWidget);

    await tester.tap(find.text('2 pairings to review'));
    await tester.pumpAndSettle();

    expect(find.byType(PairingReviewPage), findsOneWidget);
  });

  testWidgets('uses the singular for one pairing', (tester) async {
    await _pump(tester, FakePairingStore([transferSuggestion(1, 2)]));
    expect(find.text('1 pairing to review'), findsOneWidget);
  });
}
