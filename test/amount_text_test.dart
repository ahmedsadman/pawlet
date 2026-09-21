import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/finance/transaction.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/widgets/finance/amount_text.dart';

import 'support/balance_test_overrides.dart';

Future<void> _pump(
  WidgetTester tester, {
  required TxType type,
  required bool hidden,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [overrideBalanceHidden(hidden)],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Scaffold(
          body: AmountText(amount: '1234.5', currency: 'BDT', type: type),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? _color(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).style?.color;

void main() {
  testWidgets('shows a signed, colored amount when visible', (tester) async {
    await _pump(tester, type: TxType.income, hidden: false);
    expect(find.text('+1,234.50 BDT'), findsOneWidget);
    expect(_color(tester), AppTheme.income);
  });

  testWidgets('masks the value, drops the sign, keeps the color when hidden', (
    tester,
  ) async {
    await _pump(tester, type: TxType.expense, hidden: true);
    expect(find.text('**** BDT'), findsOneWidget);
    expect(find.textContaining('−'), findsNothing);
    expect(find.textContaining('1,234'), findsNothing);
    // Color is preserved even while masked.
    expect(_color(tester), AppTheme.expense);
  });
}
