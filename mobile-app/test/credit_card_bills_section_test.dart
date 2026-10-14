import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/models/finance/bill.dart';
import 'package:pawlet/models/finance/bills_page.dart';
import 'package:pawlet/models/finance/bills_query.dart';
import 'package:pawlet/models/finance/sms_message.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/bill_history_page.dart';
import 'package:pawlet/ui/widgets/finance/credit_card_bills_section.dart';
import 'package:pawlet/utils/date_range.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/balance_test_overrides.dart';

Bank _credit(String name) => Bank(
  id: 1,
  name: name,
  accountType: 'credit',
  cardDigits: '1234|5678',
  createdAt: DateTime(2025, 1, 1),
);

Bank _deposit(String name) => Bank(
  id: 2,
  name: name,
  accountType: 'deposit',
  lastBalance: '10.00',
  createdAt: DateTime(2025, 1, 1),
);

Bill _bill(int id, DateTime received, String total) => Bill(
  id: id,
  messageId: id,
  sender: 'VISA-BANK',
  receivedAt: received,
  bankId: 1,
  bankName: 'Visa',
  normalizedTotalDue: total,
  normalizedCurrency: 'BDT',
  statementPeriod: DateTime(received.year, received.month, 1),
  createdAt: received,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<Bank> banks,
  List<Bill> bills = const [],
  List<BillsQuery>? queries,
  int older = 0,
  Map<String, Object> prefsSeed = const {'bill_actions_hint_seen': true},
}) async {
  SharedPreferences.setMockInitialValues(prefsSeed);
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(prefs)),
        overrideBalanceHidden(false),
        banksProvider.overrideWith(
          (ref) async => CachedResult(data: banks, stale: false),
        ),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT', stale: false),
        ),
        billsProvider.overrideWith((ref, query) async {
          queries?.add(query);
          return CachedResult(
            data: BillsPage(
              bills: bills,
              total: bills.length,
              page: query.page,
              pageSize: query.pageSize,
            ),
            stale: false,
          );
        }),
        olderBillCountProvider.overrideWith((ref, key) async => older),
        billTransactionsProvider.overrideWith((ref, billId) async => const []),
        messageProvider.overrideWith(
          (ref, id) async => CachedResult(
            data: ApiMessage(
              id: id,
              sender: 'VISA-BANK',
              content: 'SMS body for $id',
              receivedAt: DateTime(2025, 1, 1),
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(
          body: SingleChildScrollView(child: CreditCardBillsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('is hidden entirely when there are no credit cards', (
    tester,
  ) async {
    await _pump(tester, banks: [_deposit('Checking')]);
    expect(find.text('Credit Card Bills'), findsNothing);
  });

  testWidgets('shows the latest bill and reveals previous bills on tap', (
    tester,
  ) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [
        _bill(1, DateTime(2025, 3, 5), '300.00'),
        _bill(2, DateTime(2025, 2, 5), '200.00'),
        _bill(3, DateTime(2025, 1, 5), '100.00'),
      ],
    );

    expect(find.text('Credit Card Bills'), findsOneWidget);
    // Latest (March) shown; older ones hidden.
    expect(find.text('300.00 BDT'), findsOneWidget);
    expect(find.text('200.00 BDT'), findsNothing);
    // Bill period shows the full year.
    expect(find.text('Mar 2025'), findsOneWidget);

    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();

    expect(find.text('200.00 BDT'), findsOneWidget);
    expect(find.text('100.00 BDT'), findsOneWidget);
  });

  testWidgets('asks for the last 12 months of bills', (tester) async {
    final queries = <BillsQuery>[];
    final now = DateTime.now();
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(now.year, now.month - 1, 5), '300.00')],
      queries: queries,
    );

    expect(queries, isNotEmpty);
    expect(queries.last.since, billsWindowStart(now));
    expect(queries.last.pageSize, 100);
    expect(queries.last.bankId, 1);
  });

  testWidgets('offers View more only when older bills exist', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
    );
    expect(find.text('View more'), findsNothing);
  });

  testWidgets('View more opens the card history', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
      older: 4,
    );

    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();
    expect(find.byType(BillHistoryPage), findsOneWidget);
  });

  testWidgets('a card with only older bills says so and offers View more', (
    tester,
  ) async {
    await _pump(tester, banks: [_credit('Visa')], older: 2);
    expect(find.text('No bills in the last 12 months.'), findsOneWidget);
    expect(find.text('View more'), findsOneWidget);
  });

  testWidgets('long-press on a bill opens its sheet', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
    );
    await tester.longPress(find.text('300.00 BDT'));
    await tester.pumpAndSettle();
    expect(find.text('Mark paid'), findsOneWidget);
    expect(find.text('SMS body for 1'), findsOneWidget);
  });

  testWidgets('shows the one-time hint until dismissed', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
      prefsSeed: const {},
    );
    expect(find.textContaining('long-press a bill'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('long-press a bill'), findsNothing);
  });

  testWidgets('a long-press retires the hint', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
      prefsSeed: const {},
    );
    await tester.longPress(find.text('300.00 BDT'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.text('Mark paid'))).pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('long-press a bill'), findsNothing);
  });
}
