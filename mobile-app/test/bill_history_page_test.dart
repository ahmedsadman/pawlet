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

Future<({List<BillsQuery> queries, SharedPreferences prefs})> _pump(
  WidgetTester tester, {
  List<Bill>? bills,
  Map<String, Object> prefsSeed = const {'bill_actions_hint_seen': true},
}) async {
  SharedPreferences.setMockInitialValues(prefsSeed);
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
          final pageBills = bills == null
              ? [_bill(query.page)]
              : bills
                    .skip((query.page - 1) * query.pageSize)
                    .take(query.pageSize)
                    .toList();
          return CachedResult(
            data: BillsPage(
              bills: pageBills,
              total: bills == null ? 25 : bills.length,
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
  return (queries: queries, prefs: prefs);
}

void main() {
  testWidgets('lists every bill of the card, ten per page', (tester) async {
    final result = await _pump(tester);

    expect(find.text('EBL Visa'), findsOneWidget); // app bar
    expect(find.text('1.00 BDT'), findsOneWidget);
    expect(find.text('Page 1 of 3'), findsOneWidget);
    expect(result.queries.last.pageSize, 10);
    expect(result.queries.last.since, isNull);
    expect(result.queries.last.bankId, 1);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('Page 2 of 3'), findsOneWidget);
    expect(find.text('2.00 BDT'), findsOneWidget);
    expect(result.queries.last.page, 2);
  });

  testWidgets('long-press opens the bill sheet', (tester) async {
    final result = await _pump(tester, prefsSeed: const {});
    expect(result.prefs.getBool('bill_actions_hint_seen'), isNull);
    await tester.longPress(find.text('1.00 BDT'));
    await tester.pumpAndSettle();
    expect(find.text('Mark paid'), findsOneWidget);
    expect(result.prefs.getBool('bill_actions_hint_seen'), true);
  });

  testWidgets('an empty card shows No bills yet', (tester) async {
    await _pump(tester, bills: const []);
    expect(find.text('No bills yet.'), findsOneWidget);
  });
}
