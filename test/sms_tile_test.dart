import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/sms_record.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/widgets/sms_tile.dart';

SmsRecord _rec({
  SmsStatus status = SmsStatus.queued,
  String? category,
  String? lastError,
}) => SmsRecord(
  id: 1,
  sender: 'BRAC',
  content: 'debit 50 BDT',
  timestamp: DateTime(2026, 1, 2, 15, 30).millisecondsSinceEpoch,
  status: status,
  category: category,
  lastError: lastError,
);

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: AppTheme.theme,
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('queue tile shows the status badge', (tester) async {
    await _pump(tester, SmsTile(_rec(status: SmsStatus.queued)));
    expect(find.text('BRAC'), findsOneWidget);
    expect(find.text('debit 50 BDT'), findsOneWidget);
    expect(find.text('Queued'), findsOneWidget);
  });

  testWidgets('history tile shows the read-only category label', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'transaction'),
        showCategory: true,
      ),
    );
    expect(find.text('Transaction'), findsOneWidget);
    expect(find.text('Done'), findsNothing); // no status badge in history
  });

  testWidgets('bill label in history', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'bill'),
        showCategory: true,
      ),
    );
    expect(find.text('Bill'), findsOneWidget);
  });

  testWidgets('shows the last error in queue mode', (tester) async {
    await _pump(
      tester,
      SmsTile(_rec(status: SmsStatus.queued, lastError: 'rate limited')),
    );
    expect(find.text('rate limited'), findsOneWidget);
  });
}
