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
      banksProvider.overrideWith(
        (ref) async => const CachedResult(data: <Bank>[]),
      ),
    ]);
    expect(find.text('No banks yet'), findsOneWidget);
  });

  testWidgets('lists a bank', (tester) async {
    await _pump(tester, const BanksPage(), [
      banksProvider.overrideWith(
        (ref) async => CachedResult(data: [_bank('City Bank')]),
      ),
    ]);
    expect(find.text('City Bank'), findsOneWidget);
    expect(find.text('No banks yet'), findsNothing);
  });

  testWidgets('form shows the bank picker + conditional credit fields', (
    tester,
  ) async {
    await _pump(tester, const BankFormPage(), const []);

    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.textContaining('Pick your bank'), findsOneWidget);
    // Deposit is the default → balance field, no card-digit fields.
    expect(
      find.widgetWithText(TextFormField, 'Current balance (optional)'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextFormField, 'First 4'), findsNothing);

    await tester.tap(find.text('Credit card'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.widgetWithText(TextFormField, 'First 4'), findsOneWidget);
    expect(
      find.widgetWithText(TextFormField, 'Current balance (optional)'),
      findsNothing,
    );
  });

  testWidgets('selecting a bank from the catalog updates the picker', (
    tester,
  ) async {
    // No real DB (widget tests can't drive sqflite under FakeAsync); the
    // catalog→matchers→persist path is covered by bank_catalog / banks_repository
    // tests. Here we only verify the picker works.
    await _pump(tester, const BankFormPage(), const []);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MTB').last);
    await tester.pumpAndSettle();

    expect(find.text('MTB'), findsOneWidget); // now selected
  });
}
