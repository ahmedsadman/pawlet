import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/total_balance_card.dart';

import 'support/balance_test_overrides.dart';

Bank _deposit(String name, String? balance) => Bank(
  id: name.hashCode,
  name: name,
  accountType: 'deposit',
  lastBalance: balance,
  lastBalanceAt: DateTime(2025, 1, 1),
  createdAt: DateTime(2025, 1, 1),
);

Bank _credit(String name) => Bank(
  id: name.hashCode,
  name: name,
  accountType: 'credit',
  cardDigits: '1234|5678',
  createdAt: DateTime(2025, 1, 1),
);

Future<void> _pump(
  WidgetTester tester,
  List<Bank> banks, {
  bool hidden = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(hidden),
        banksProvider.overrideWith(
          (ref) async => CachedResult(data: banks, stale: false),
        ),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT', stale: false),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: TotalBalanceCard()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sums deposit balances and hides the breakdown by default', (
    tester,
  ) async {
    await _pump(tester, [
      _deposit('Checking', '1000.00'),
      _deposit('Savings', '500.50'),
      _credit('Visa'),
    ]);

    expect(find.text('Total Balance'), findsOneWidget);
    expect(find.text('1,500.50 BDT'), findsOneWidget);
    expect(find.text('Checking'), findsNothing);
  });

  testWidgets('tapping toggles the per-bank breakdown', (tester) async {
    await _pump(tester, [_deposit('Checking', '1000.00'), _credit('Visa')]);

    await tester.tap(find.text('Total Balance'));
    await tester.pumpAndSettle();

    expect(find.text('Checking'), findsOneWidget);
    expect(find.text('Visa'), findsOneWidget);
    expect(find.textContaining('not counted'), findsOneWidget);

    await tester.tap(find.text('Total Balance'));
    await tester.pumpAndSettle();
    expect(find.text('Checking'), findsNothing);
  });

  testWidgets('shows the Add Bank CTA when there are no banks', (tester) async {
    await _pump(tester, const []);
    expect(find.text('Add a bank to get started'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add Bank'), findsOneWidget);
    // No balance figure or expand affordance in the empty state.
    expect(find.text('—'), findsNothing);
  });

  testWidgets('masks the total when balances are hidden', (tester) async {
    await _pump(tester, [_deposit('Checking', '1000.00')], hidden: true);

    expect(find.text('1,000.00 BDT'), findsNothing);
    expect(find.text('**** BDT'), findsOneWidget);
  });
}
