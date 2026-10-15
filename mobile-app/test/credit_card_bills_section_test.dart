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
import 'package:shared_preferences/shared_preferences.dart';

import 'support/balance_test_overrides.dart';

Bank _credit(String name, {int id = 1}) => Bank(
  id: id,
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

Bill _bill(int id, DateTime received, String total, {int bankId = 1}) => Bill(
  id: id,
  messageId: id,
  sender: 'VISA-BANK',
  receivedAt: received,
  bankId: bankId,
  bankName: 'Visa',
  normalizedTotalDue: total,
  normalizedCurrency: 'BDT',
  statementPeriod: DateTime(received.year, received.month, 1),
  createdAt: received,
);

Future<SharedPreferences> _pump(
  WidgetTester tester, {
  required List<Bank> banks,
  List<Bill> bills = const [],
  List<BillsQuery>? queries,
  int? total,
  Map<String, Object> prefsSeed = const {'bill_actions_hint_seen': true},
  bool tall = false,
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
          final own = bills.where((b) => b.bankId == query.bankId).toList();
          return CachedResult(
            data: BillsPage(
              bills: own,
              total: total ?? own.length,
              page: query.page,
              pageSize: query.pageSize,
            ),
            stale: false,
          );
        }),
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
        home: Scaffold(
          body: SingleChildScrollView(
            // Tall surroundings leave room to scroll the section mid-screen.
            child: tall
                ? const Column(
                    children: [
                      SizedBox(height: 400),
                      CreditCardBillsSection(),
                      SizedBox(height: 2000),
                    ],
                  )
                : const CreditCardBillsSection(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
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

  testWidgets("asks for each card's latest 12 bills", (tester) async {
    final queries = <BillsQuery>[];
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
      queries: queries,
    );

    expect(queries, isNotEmpty);
    expect(queries.last.pageSize, 12);
    expect(queries.last.page, 1);
    expect(queries.last.bankId, 1);
  });

  // Two bills so the card header expands.
  final twoBills = [
    _bill(1, DateTime(2025, 3, 5), '300.00'),
    _bill(2, DateTime(2025, 2, 5), '200.00'),
  ];

  testWidgets('hides View more while the card is collapsed', (tester) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills, total: 20);
    expect(find.text('View more'), findsNothing);
  });

  testWidgets('offers View more on an expanded card with over 12 bills', (
    tester,
  ) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills, total: 13);
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('View more'), findsOneWidget);
  });

  testWidgets('no View more on an expanded card with exactly 12 bills', (
    tester,
  ) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills, total: 12);
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsOneWidget);
    expect(find.text('View more'), findsNothing);
  });

  testWidgets('View more opens the card history', (tester) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills, total: 20);
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('View more'));
    await tester.pumpAndSettle();
    expect(find.byType(BillHistoryPage), findsOneWidget);
  });

  testWidgets('expanding one card collapses the other', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa'), _credit('Amex', id: 5)],
      bills: [
        ...twoBills,
        _bill(11, DateTime(2025, 3, 7), '310.00', bankId: 5),
        _bill(12, DateTime(2025, 2, 7), '210.00', bankId: 5),
      ],
    );
    expect(find.text('200.00 BDT'), findsNothing);
    expect(find.text('210.00 BDT'), findsNothing);

    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsOneWidget);
    expect(find.text('210.00 BDT'), findsNothing);

    await tester.tap(find.text('Amex'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    // Mid-animation: Visa is still collapsing while Amex expands.
    expect(find.text('200.00 BDT'), findsOneWidget);
    expect(find.text('210.00 BDT'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsNothing);
    expect(find.text('210.00 BDT'), findsOneWidget);

    // Tapping the open card's header collapses it.
    await tester.tap(find.text('Amex'));
    await tester.pumpAndSettle();
    expect(find.text('210.00 BDT'), findsNothing);
  });

  testWidgets('a card without bills says so', (tester) async {
    await _pump(tester, banks: [_credit('Visa')], total: 0);
    expect(find.text('No bills yet.'), findsOneWidget);
    expect(find.text('View more'), findsNothing);
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
    final prefs = await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: [_bill(1, DateTime(2025, 3, 5), '300.00')],
      prefsSeed: const {},
    );
    expect(find.textContaining('long-press a bill'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('long-press a bill'), findsNothing);
    expect(prefs.getBool('bill_actions_hint_seen'), true);
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

  testWidgets('no hint when card has no bills', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa')],
      bills: const [],
      prefsSeed: const {},
    );
    expect(find.textContaining('long-press a bill'), findsNothing);
  });

  testWidgets('tapping the latest bill row expands and collapses the card', (
    tester,
  ) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills);
    // Second bill hidden initially.
    expect(find.text('200.00 BDT'), findsNothing);

    // Tap the latest bill's amount to expand.
    await tester.tap(find.text('300.00 BDT'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsOneWidget);

    // Tap again to collapse.
    await tester.tap(find.text('300.00 BDT'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsNothing);
  });

  testWidgets(
    'long-pressing the latest bill opens the sheet without expanding',
    (tester) async {
      await _pump(tester, banks: [_credit('Visa')], bills: twoBills);
      expect(find.text('200.00 BDT'), findsNothing);

      await tester.longPress(find.text('300.00 BDT'));
      await tester.pumpAndSettle();
      expect(find.text('Mark paid'), findsOneWidget);

      // Close the sheet.
      Navigator.of(tester.element(find.text('Mark paid'))).pop();
      await tester.pumpAndSettle();

      // Card should still be collapsed.
      expect(find.text('200.00 BDT'), findsNothing);
    },
  );

  testWidgets('tapping an older row while expanded keeps the card expanded', (
    tester,
  ) async {
    await _pump(tester, banks: [_credit('Visa')], bills: twoBills);
    // Expand the card.
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsOneWidget);

    // Tap the older bill.
    await tester.tap(find.text('200.00 BDT'));
    await tester.pumpAndSettle();

    // Should still be expanded.
    expect(find.text('200.00 BDT'), findsOneWidget);
  });

  testWidgets('one-bill card stays non-tappable in accordion', (tester) async {
    await _pump(
      tester,
      banks: [_credit('Visa'), _credit('Amex', id: 5)],
      bills: [
        ...twoBills,
        _bill(11, DateTime(2025, 3, 7), '310.00', bankId: 5),
      ],
    );
    // Expand Visa.
    await tester.tap(find.text('Visa'));
    await tester.pumpAndSettle();
    expect(find.text('200.00 BDT'), findsOneWidget);

    // Tap Amex header (one bill, so header is non-interactive).
    await tester.tap(find.text('Amex'));
    await tester.pumpAndSettle();

    // Visa should still be expanded.
    expect(find.text('200.00 BDT'), findsOneWidget);

    // Tap Amex's only bill.
    await tester.tap(find.text('310.00 BDT'));
    await tester.pumpAndSettle();

    // Visa should still be expanded.
    expect(find.text('200.00 BDT'), findsOneWidget);

    // Only Visa's chevron should exist.
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
  });

  group('scroll anchoring', () {
    // Visa (id 1) above Amex (id 5), six bills each.
    final banks = [_credit('Visa'), _credit('Amex', id: 5)];
    final bills = [
      for (var m = 1; m <= 6; m++) ...[
        _bill(m, DateTime(2025, 7 - m, 5), '${m}00.00'),
        _bill(10 + m, DateTime(2025, 7 - m, 7), '${m}10.00', bankId: 5),
      ],
    ];
    ScrollPosition position(WidgetTester tester) =>
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;

    testWidgets(
      'switching to a card below the open one keeps its header still',
      (tester) async {
        await _pump(tester, banks: banks, bills: bills, tall: true);
        await tester.tap(find.text('Visa'));
        await tester.pumpAndSettle();
        expect(find.text('600.00 BDT'), findsOneWidget);

        // Scroll Amex's header to mid-screen, below the open Visa list.
        final amexTop = tester.getTopLeft(find.text('Amex')).dy;
        position(tester).jumpTo(position(tester).pixels + amexTop - 300);
        await tester.pump();
        final before = tester.getTopLeft(find.text('Amex')).dy;
        expect(before, closeTo(300, 1));

        await tester.tap(find.text('Amex'));
        var elapsed = 0;
        for (final ms in [0, 50, 125, 250]) {
          await tester.pump(Duration(milliseconds: ms - elapsed));
          elapsed = ms;
          expect(
            tester.getTopLeft(find.text('Amex')).dy,
            closeTo(before, 1),
            reason: '${ms}ms into the animation',
          );
        }
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(find.text('Amex')).dy, closeTo(before, 1));
        expect(find.text('600.00 BDT'), findsNothing);
        expect(find.text('610.00 BDT'), findsOneWidget);
      },
    );

    testWidgets('collapsing the open card leaves the scroll alone', (
      tester,
    ) async {
      await _pump(tester, banks: banks, bills: bills, tall: true);
      position(tester).jumpTo(200);
      await tester.pump();

      await tester.tap(find.text('Amex'));
      await tester.pumpAndSettle();
      expect(find.text('610.00 BDT'), findsOneWidget);
      expect(position(tester).pixels, 200);

      await tester.tap(find.text('Amex'));
      await tester.pumpAndSettle();
      expect(find.text('610.00 BDT'), findsNothing);
      expect(position(tester).pixels, 200);
    });

    testWidgets('switching to a card above the open one needs no anchor', (
      tester,
    ) async {
      await _pump(tester, banks: banks, bills: bills, tall: true);
      position(tester).jumpTo(200);
      await tester.tap(find.text('Amex'));
      await tester.pumpAndSettle();

      final visaTop = tester.getTopLeft(find.text('Visa')).dy;
      await tester.tap(find.text('Visa'));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Visa')).dy, visaTop);
      expect(find.text('600.00 BDT'), findsOneWidget);
      expect(find.text('610.00 BDT'), findsNothing);
      expect(position(tester).pixels, 200);
    });
  });
}
