import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/transaction_entry_sheet.dart';

/// A repository whose manual insert always fails, to drive the sheet's error
/// path. Only [insertManualTransaction] is exercised; other members throw.
class _ThrowingRepo implements FinanceRepository {
  @override
  Future<int> insertManualTransaction({
    required int bankId,
    required String amount,
    required TxType type,
    required DateTime date,
    String? currency,
  }) async => throw Exception('disk full');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  Bank bank(int id, String name) => Bank(
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
    List<Override> extra = const [],
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
          ...extra,
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
    await openSheet(tester, banks: [bank(1, 'City'), bank(2, 'EBL')]);
    expect(find.text('Select Bank'), findsOneWidget);
    expect(find.text('Amount'), findsOneWidget);
    expect(find.text('Income'), findsOneWidget);
    expect(find.text('Expense'), findsOneWidget);
    // Manual add offers all three types, including Transfer.
    expect(find.text('Transfer'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Add transaction'),
      findsOneWidget,
    );
  });

  testWidgets('blocks save until a bank and valid amount are set', (
    tester,
  ) async {
    await openSheet(tester, banks: [bank(1, 'City')]);
    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();
    // Validation errors keep the sheet open (both the unselected bank and the
    // empty amount are flagged).
    expect(
      find.widgetWithText(FilledButton, 'Add transaction'),
      findsOneWidget,
    );
    expect(find.text('Please select a bank'), findsOneWidget);
    expect(find.text('Enter a valid amount'), findsOneWidget);
  });

  testWidgets('picks a bank via the picker sheet', (tester) async {
    await openSheet(tester, banks: [bank(1, 'City'), bank(2, 'EBL')]);
    await tester.tap(find.text('Select Bank'));
    await tester.pumpAndSettle();
    // Picker lists the banks; choose one.
    await tester.tap(find.text('EBL').last);
    await tester.pumpAndSettle();
    // Chosen bank now shown on the field.
    expect(find.text('EBL'), findsOneWidget);
  });

  testWidgets('a failed insert shows an error and keeps the sheet open', (
    tester,
  ) async {
    await openSheet(
      tester,
      banks: [bank(1, 'City')],
      extra: [financeRepositoryProvider.overrideWithValue(_ThrowingRepo())],
    );

    // Pick the (only) bank and a valid amount so the insert is attempted.
    await tester.tap(find.text('Select Bank'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('City').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '10');

    await tester.tap(find.widgetWithText(FilledButton, 'Add transaction'));
    await tester.pumpAndSettle();

    // Failure surfaced; sheet stays open and the button is usable again.
    expect(find.textContaining('Could not add transaction'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Add transaction'),
      findsOneWidget,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Add transaction'),
    );
    expect(button.onPressed, isNotNull);
  });
}
