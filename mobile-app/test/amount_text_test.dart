import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/finance/amount_text.dart';

Future<void> _pump(WidgetTester tester, {required TxType type}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.theme,
      home: Scaffold(
        body: AmountText(amount: '1234.5', currency: 'BDT', type: type),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color? _color(WidgetTester tester) =>
    tester.widget<Text>(find.byType(Text)).style?.color;

void main() {
  testWidgets('shows a signed, colored amount', (tester) async {
    await _pump(tester, type: TxType.income);
    expect(find.text('+1,234.50 BDT'), findsOneWidget);
    expect(_color(tester), AppTheme.income);
  });
}
