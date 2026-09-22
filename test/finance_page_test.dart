import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/state/providers.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/finance_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/finance_overrides.dart';

Bank _deposit(String name, String balance) => Bank(
  id: name.hashCode,
  name: name,
  accountType: 'deposit',
  lastBalance: balance,
  lastBalanceAt: DateTime(2026, 1, 1),
  createdAt: DateTime(2026, 1, 1),
);

Future<void> _pump(WidgetTester tester, List<Bank> banks) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...financeOverrides(banks: banks),
        sharedPreferencesProvider.overrideWithValue(prefs),
      ],
      child: MaterialApp(theme: AppTheme.theme, home: const FinancePage()),
    ),
  );
  // Resolve the (canned) futures then let finite chart animations run. Avoid
  // pumpAndSettle: the loading skeletons animate indefinitely.
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('empty database shows the Meowni header and Add Bank CTA', (
    tester,
  ) async {
    await _pump(tester, const []);
    expect(find.widgetWithText(AppBar, 'Meowni'), findsOneWidget);
    expect(find.text('Add a bank to get started'), findsOneWidget);
  });

  testWidgets('renders the total balance from a deposit bank', (tester) async {
    await _pump(tester, [_deposit('Checking', '2000.00')]);
    expect(find.text('Total Balance'), findsOneWidget);
    expect(find.text('2,000.00 BDT'), findsOneWidget);
    expect(find.text('Add a bank to get started'), findsNothing);
  });
}
