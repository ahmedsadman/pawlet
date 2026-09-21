import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/widgets/skeleton.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.theme,
      home: Scaffold(body: child),
    ),
  );
  // Skeletons animate forever; pump a frame instead of settling.
  await tester.pump();
}

void main() {
  testWidgets('transaction skeleton renders one row per requested count', (
    tester,
  ) async {
    await _pump(tester, const TransactionRowsSkeleton(count: 4));

    // One divider per row, and three skeleton blocks per row.
    expect(find.byType(Divider), findsNWidgets(4));
    expect(find.byType(Skeleton), findsNWidgets(12));
  });

  testWidgets('sms tiles skeleton renders the requested number of cards', (
    tester,
  ) async {
    await _pump(tester, const SmsTilesSkeleton(count: 3));

    expect(find.byType(Card), findsNWidgets(3));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
