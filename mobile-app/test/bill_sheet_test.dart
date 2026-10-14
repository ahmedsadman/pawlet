import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/models/finance/bill.dart';
import 'package:pawlet/models/finance/sms_message.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/services/finance/bill_actions.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/bill_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/balance_test_overrides.dart';

class _FakeBillActions implements BillActions {
  final calls = <(int, bool)>[];

  @override
  Future<void> setPaid(int billId, {required bool paid}) async =>
      calls.add((billId, paid));
}

Bill _bill({DateTime? paidAt, List<int> links = const []}) => Bill(
  id: 7,
  messageId: 70,
  sender: 'EBL',
  receivedAt: DateTime(2026, 9, 5),
  bankId: 1,
  bankName: 'EBL Visa',
  normalizedTotalDue: '8020.00',
  normalizedCurrency: 'BDT',
  statementPeriod: DateTime(2026, 9, 1),
  paidAt: paidAt,
  linkedTransactionIds: links,
  createdAt: DateTime(2026, 9, 5),
);

TransactionItem _leg(int id, {int? messageId, String bank = 'MTB'}) =>
    TransactionItem(
      id: id,
      messageId: messageId,
      bankName: bank,
      sender: bank,
      normalizedAmount: '8020.00',
      normalizedCurrency: 'BDT',
      type: TxType.transfer,
      date: DateTime(2026, 9, 10),
    );

Future<(_FakeBillActions, SharedPreferences)> _pump(
  WidgetTester tester,
  Bill bill, {
  bool hidden = false,
  List<TransactionItem> legs = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final actions = _FakeBillActions();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(SettingsRepository(prefs)),
        overrideBalanceHidden(hidden),
        billActionsProvider.overrideWithValue(actions),
        currencyProvider.overrideWith(
          (ref) async => const CachedResult(data: 'BDT'),
        ),
        billTransactionsProvider.overrideWith((ref, billId) async => legs),
        messageProvider.overrideWith(
          (ref, id) async => CachedResult(
            data: ApiMessage(
              id: id,
              sender: 'SENDER-$id',
              content: 'SMS body for $id',
              receivedAt: DateTime(2026, 9, 5),
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showBillSheet(context, ref, bill),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (actions, prefs);
}

void main() {
  testWidgets('shows the bill SMS and marks an unpaid bill paid', (
    tester,
  ) async {
    final (actions, _) = await _pump(tester, _bill());

    expect(find.text('SMS body for 70'), findsOneWidget);
    expect(find.text('Due'), findsOneWidget);
    await tester.tap(find.text('Mark paid'));
    await tester.pumpAndSettle();

    expect(actions.calls, [(7, true)]);
    expect(find.text('Mark paid'), findsNothing); // sheet closed
  });

  testWidgets('unpaying a bill with no linked payment needs no confirm', (
    tester,
  ) async {
    final (actions, _) = await _pump(
      tester,
      _bill(paidAt: DateTime(2026, 9, 12)),
    );

    expect(find.text('Paid'), findsOneWidget);
    await tester.tap(find.text('Mark unpaid'));
    await tester.pumpAndSettle();

    expect(actions.calls, [(7, false)]);
  });

  testWidgets('unpaying a bill with a linked payment asks first', (
    tester,
  ) async {
    final (actions, _) = await _pump(
      tester,
      _bill(paidAt: DateTime(2026, 9, 12), links: [1, 2]),
      legs: [
        _leg(1, messageId: 11),
        _leg(2, messageId: 12, bank: 'EBL'),
      ],
    );

    await tester.tap(find.text('Mark unpaid'));
    await tester.pumpAndSettle();
    expect(find.textContaining('unlinks the payment'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(actions.calls, isEmpty);

    await tester.tap(find.text('Mark unpaid'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unlink'));
    await tester.pumpAndSettle();
    expect(actions.calls, [(7, false)]);
  });

  testWidgets('lists the payment legs, SMS or manual', (tester) async {
    await _pump(
      tester,
      _bill(paidAt: DateTime(2026, 9, 12), links: [1, 2]),
      legs: [
        _leg(1, messageId: 11),
        _leg(2, bank: 'Cash'),
      ],
    );

    expect(find.text('Payment'), findsOneWidget);
    expect(find.text('SMS body for 11'), findsOneWidget);
    expect(find.textContaining('Cash'), findsOneWidget);
  });

  testWidgets('hides SMS bodies while balances are hidden', (tester) async {
    final (actions, _) = await _pump(tester, _bill(), hidden: true);

    expect(find.text('SMS body for 70'), findsNothing);
    expect(find.text('Hidden while balances are hidden.'), findsOneWidget);
    await tester.tap(find.text('Mark paid'));
    await tester.pumpAndSettle();
    expect(actions.calls, [(7, true)]);
  });

  testWidgets('opening the sheet retires the bill hint', (tester) async {
    final (_, prefs) = await _pump(tester, _bill());
    expect(prefs.getBool('bill_actions_hint_seen'), isTrue);
  });
}
