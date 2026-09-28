import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/transaction_entry_sheet.dart';

void main() {
  Bank _bank(int id, String name) => Bank(
    id: id,
    name: name,
    accountType: 'deposit',
    createdAt: DateTime(2026, 1, 1),
    matchers: const [],
  );

  // Pumps a host with an "open" button that launches the sheet, then taps it.
  Future<void> openSheet(
    WidgetTester tester, {
    List<Bank> banks = const [],
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          banksProvider.overrideWith(
            (ref) async => CachedResult(data: banks, stale: false),
          ),
          currencyProvider.overrideWith(
            (ref) async => const CachedResult(data: 'BDT', stale: false),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.theme,
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showAddTransactionSheet(context),
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
  }

  testWidgets('shows an empty-state CTA when no banks exist', (tester) async {
    await openSheet(tester, banks: const []);
    expect(find.textContaining('Add a bank first'), findsOneWidget);
  });

  testWidgets('renders bank picker, amount, type and date when banks exist', (
    tester,
  ) async {
    await openSheet(tester, banks: [_bank(1, 'City'), _bank(2, 'EBL')]);
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);
    expect(find.text('Amount'), findsOneWidget);
    expect(find.text('Income'), findsOneWidget);
    expect(find.text('Expense'), findsOneWidget);
    // Manual add offers only income/expense (no Transfer).
    expect(find.text('Transfer'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Add transaction'),
      findsOneWidget,
    );
  });

  testWidgets('blocks save until a bank and valid amount are set', (
    tester,
  ) async {
    await openSheet(tester, banks: [_bank(1, 'City')]);
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();
    // Validation errors keep the sheet open.
    expect(find.widgetWithText(FilledButton, 'Add transaction'), findsOneWidget);
    expect(find.text('Enter a valid amount'), findsOneWidget);
  });
}
