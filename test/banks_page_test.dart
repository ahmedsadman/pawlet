import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/finance_repository.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/state/finance_providers.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/banks_page.dart';

Bank _bank(String name) => Bank(
  id: name.hashCode,
  name: name,
  accountType: 'deposit',
  lastBalance: '100.00',
  createdAt: DateTime(2026, 1, 1),
);

Future<void> _pump(WidgetTester tester, Widget home, List<Override> o) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: o,
      child: MaterialApp(theme: AppTheme.theme, home: home),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('shows the empty state when there are no banks', (tester) async {
    await _pump(tester, const BanksPage(), [
      banksProvider.overrideWith((ref) async => const CachedResult(data: <Bank>[])),
    ]);
    expect(find.text('No banks yet'), findsOneWidget);
  });

  testWidgets('lists a bank', (tester) async {
    await _pump(tester, const BanksPage(), [
      banksProvider.overrideWith(
        (ref) async => CachedResult(data: [_bank('BRAC Bank')]),
      ),
    ]);
    expect(find.text('BRAC Bank'), findsOneWidget);
    expect(find.text('No banks yet'), findsNothing);
  });

  testWidgets('form renders name, alternate names + help, and conditional '
      'credit-card digit fields', (tester) async {
    await _pump(tester, const BankFormPage(), const []);

    expect(find.widgetWithText(TextFormField, 'Name'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Alternate sender names'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Sender-name matching decides'),
      findsOneWidget,
    );
    // Deposit is the default → balance field, no card-digit fields.
    expect(
      find.widgetWithText(TextFormField, 'Current balance (optional)'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextFormField, 'First 4'), findsNothing);

    // Switch to credit card → digit fields appear, balance field goes away.
    await tester.tap(find.text('Credit card'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.widgetWithText(TextFormField, 'First 4'), findsOneWidget);
    expect(find.widgetWithText(TextFormField, 'Last 4'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Current balance (optional)'),
      findsNothing,
    );
  });
}
