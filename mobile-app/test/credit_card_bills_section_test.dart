import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/models/finance/bill.dart';
import 'package:pawlet/models/finance/bills_page.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/credit_card_bills_section.dart';

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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        overrideBalanceHidden(false),
        banksProvider.overrideWith(
          (ref) async => CachedResult(data: banks, stale: false),
        ),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT', stale: false),
        ),
        billsProvider.overrideWith(
          (ref, bankId) async => CachedResult(
            data: BillsPage(
              bills: bills,
              total: bills.length,
              page: 1,
              pageSize: 20,
            ),
            stale: false,
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

    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();

    expect(find.text('200.00 BDT'), findsOneWidget);
    expect(find.text('100.00 BDT'), findsOneWidget);
  });
}
