import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/pairing_suggestion.dart';
import 'package:pawlet/models/finance/sms_message.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/pairing_card.dart';

import 'support/balance_test_overrides.dart';
import 'support/pairing_fakes.dart';

Future<List<bool>> _pump(
  WidgetTester tester,
  PairingSuggestion s, {
  bool hidden = false,
}) async {
  final answers = <bool>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(hidden),
        messageProvider.overrideWith(
          (ref, id) async => CachedResult(
            data: ApiMessage(
              id: id,
              sender: 'SENDER$id',
              content: 'Body of message $id',
              receivedAt: DateTime(2026, 10, 14),
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: PairingCard(suggestion: s, onAnswer: answers.add),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return answers;
}

void main() {
  testWidgets('a transfer card shows both legs, gap and difference', (
    tester,
  ) async {
    await _pump(tester, transferSuggestion(1, 2, otherMatches: 1));

    expect(find.text('TRANSFER'), findsOneWidget);
    expect(find.text('Are these one internal transfer?'), findsOneWidget);
    expect(find.text('MTB'), findsOneWidget);
    expect(find.text('City Bank'), findsOneWidget);
    expect(find.text('−1,510.00 BDT'), findsOneWidget);
    expect(find.text('+1,500.00 BDT'), findsOneWidget);
    expect(find.text('2h apart · 10.00 BDT difference'), findsOneWidget);
    expect(find.text('1 more transaction also matches'), findsOneWidget);
  });

  testWidgets('a card-payment card names the card', (tester) async {
    await _pump(tester, cardSuggestion(1, 2));

    expect(find.text('CARD'), findsOneWidget);
    expect(find.text('Did this pay your card?'), findsOneWidget);
    expect(find.text('EBL ••1234'), findsOneWidget);
    expect(find.text('1d 3h apart'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets('Yes and No report the answer', (tester) async {
    final answers = await _pump(tester, transferSuggestion(1, 2));

    await tester.tap(find.text('No'));
    await tester.tap(find.text('Yes, pair'));

    expect(answers, [false, true]);
  });

  testWidgets('Show messages reveals both backing texts', (tester) async {
    await _pump(
      tester,
      transferSuggestion(1, 2, fromMessage: 11, toMessage: 12),
    );

    await tester.tap(find.text('Show messages'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Body of message 11'), findsOneWidget);
    expect(find.text('Body of message 12'), findsOneWidget);
    expect(find.text('Hide messages'), findsOneWidget);
  });

  testWidgets('hidden balances mask the difference and the messages', (
    tester,
  ) async {
    await _pump(
      tester,
      transferSuggestion(1, 2, fromMessage: 11, toMessage: 12),
      hidden: true,
    );

    expect(find.text('2h apart'), findsOneWidget);
    expect(find.textContaining('difference'), findsNothing);
    expect(find.text('Show messages'), findsNothing);
  });
}
