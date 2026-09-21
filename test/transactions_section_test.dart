import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meowni/data/finance_repository.dart';
import 'package:meowni/data/settings_repository.dart';
import 'package:meowni/models/finance/sms_message.dart';
import 'package:meowni/models/finance/transaction.dart';
import 'package:meowni/models/finance/transactions_page.dart';
import 'package:meowni/state/finance_providers.dart';
import 'package:meowni/state/providers.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/widgets/finance/transactions_section.dart';

TransactionItem _tx(int id, TxType type, String amount) => TransactionItem(
  id: id,
  messageId: 100 + id,
  sender: 'ACME-$id',
  normalizedAmount: amount,
  normalizedCurrency: 'BDT',
  type: type,
  date: DateTime(2025, 1, id + 1),
);

TransactionsPage _page(int page) => TransactionsPage(
  transactions: [_tx(1, TxType.expense, '50.00')],
  total: 25,
  page: page,
  pageSize: 10,
  totals: const Totals(income: '900.00', expense: '300.00'),
);

Future<void> _pump(
  WidgetTester tester, {
  Map<String, Object> prefsSeed = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(prefs)),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT', stale: false),
        ),
        transactionsProvider.overrideWith(
          (ref, query) async =>
              CachedResult(data: _page(query.page), stale: false),
        ),
        messageProvider.overrideWith(
          (ref, id) async => CachedResult(
            data: ApiMessage(
              id: id,
              sender: 'ACME',
              content: 'SMS body for $id',
              receivedAt: DateTime(2025, 1, 1),
            ),
            stale: false,
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(
          body: SingleChildScrollView(child: TransactionsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows totals and a color-coded row', (tester) async {
    await _pump(tester);

    // Income/Expense totals (the value is unique; the labels also appear in the
    // type-filter chips, so assert on the amounts).
    expect(find.text('900.00 BDT'), findsOneWidget);
    expect(find.text('300.00 BDT'), findsOneWidget);
    expect(find.text('ACME-1'), findsOneWidget);
    expect(find.text('−50.00 BDT'), findsOneWidget); // expense sign
  });

  testWidgets('tapping a row reveals the backing message', (tester) async {
    await _pump(tester);

    expect(find.text('SMS body for 101'), findsNothing);
    await tester.tap(find.text('ACME-1'));
    await tester.pumpAndSettle();
    expect(find.text('SMS body for 101'), findsOneWidget);
  });

  testWidgets('masks amounts and blocks row expansion when hidden', (
    tester,
  ) async {
    await _pump(tester, prefsSeed: const {'hide_balance': true});

    // Totals and the row amount are masked (currency kept, sign dropped).
    expect(find.text('900.00 BDT'), findsNothing);
    expect(find.text('300.00 BDT'), findsNothing);
    expect(find.text('−50.00 BDT'), findsNothing);
    expect(find.text('**** BDT'), findsWidgets);

    // Tapping a row must NOT reveal the backing SMS (it contains the amount).
    await tester.tap(find.text('ACME-1'));
    await tester.pumpAndSettle();
    expect(find.text('SMS body for 101'), findsNothing);
  });

  testWidgets('paginates when there is more than one page', (tester) async {
    await _pump(tester);

    expect(find.text('Page 1 of 3'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);
  });

  testWidgets('restores persisted filters on load', (tester) async {
    await _pump(
      tester,
      prefsSeed: const {
        'tx_range': 'last_3_months',
        'tx_sort': 'amount-desc',
        'tx_types': 'income',
      },
    );

    // The date-range selector and sort dropdown reflect the saved choices, and
    // a non-default state exposes the Reset affordance.
    expect(find.text('Last 3 months'), findsOneWidget);
    expect(find.text('Highest amount'), findsOneWidget);
    expect(find.text('Reset'), findsOneWidget);
  });
}
