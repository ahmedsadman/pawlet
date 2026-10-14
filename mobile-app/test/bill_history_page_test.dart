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
import 'package:shared_preferences/shared_preferences.dart';

import 'support/balance_test_overrides.dart';

final _bank = Bank(
  id: 1,
  name: 'EBL Visa',
  accountType: 'credit',
  cardDigits: '4238|1234',
  createdAt: DateTime(2025, 1, 1),
);

Bill _bill(int id) => Bill(
  id: id,
  messageId: 100 + id,
  sender: 'EBL',
  receivedAt: DateTime(2024, id, 5),
  bankId: 1,
  bankName: 'EBL Visa',
  normalizedTotalDue: '$id.00',
  normalizedCurrency: 'BDT',
  statementPeriod: DateTime(2024, id, 1),
  createdAt: DateTime(2024, id, 5),
);

Future<List<BillsQuery>> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final queries = <BillsQuery>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(prefs)),
        overrideBalanceHidden(false),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT'),
        ),
        billsProvider.overrideWith((ref, query) async {
          queries.add(query);
          return CachedResult(
            data: BillsPage(
              bills: [_bill(query.page)],
              total: 25,
              page: query.page,
              pageSize: query.pageSize,
            ),
          );
        }),
        billTransactionsProvider.overrideWith((ref, billId) async => const []),
        messageProvider.overrideWith(
          (ref, id) async => CachedResult(
            data: ApiMessage(
              id: id,
              sender: 'EBL',
              content: 'SMS body for $id',
              receivedAt: DateTime(2024, 1, 5),
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: BillHistoryPage(bank: _bank),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return queries;
}

void main() {
  testWidgets('lists every bill of the card, ten per page', (tester) async {
    final queries = await _pump(tester);

    expect(find.text('EBL Visa'), findsOneWidget); // app bar
    expect(find.text('1.00 BDT'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(queries.last.pageSize, 10);
    expect(queries.last.since, isNull);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);
    expect(find.text('2.00 BDT'), findsOneWidget);
    expect(queries.last.page, 2);
  });

  testWidgets('long-press opens the bill sheet', (tester) async {
    await _pump(tester);
    await tester.longPress(find.text('1.00 BDT'));
    await tester.pumpAndSettle();
    expect(find.text('Mark paid'), findsOneWidget);
  });
}
