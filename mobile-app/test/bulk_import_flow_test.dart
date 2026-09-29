import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/bulk_import/bulk_import_service.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/bulk_import_flow.dart';

Widget _host(void Function(BuildContext) onTap) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.theme,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => onTap(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('the offer sheet states the on-device-only terms', (
    tester,
  ) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await confirmBulkImport(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Import existing messages'), findsOneWidget);
    expect(
      find.textContaining(
        'This pass only uses the on-device model for metadata extraction',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('low confidence score will be skipped'),
      findsOneWidget,
    );

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('dismissing the offer sheet counts as declining', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await confirmBulkImport(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Swipe the sheet away rather than pressing a button.
    await tester.fling(
      find.text('Import existing messages'),
      const Offset(0, 600),
      1000,
    );
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('the offer sheet reports acceptance', (tester) async {
    bool? answer;
    await tester.pumpWidget(
      _host((context) async => answer = await confirmBulkImport(context)),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import now'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
  });

  testWidgets('the summary shows both totals and both caveats', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showBulkImportSummary(
          context,
          const BulkImportResult(scanned: 812, saved: 47, cancelled: false),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Import complete'), findsOneWidget);
    expect(find.text('812'), findsOneWidget);
    expect(find.text('47'), findsOneWidget);
    expect(find.textContaining('no LLM'), findsOneWidget);
    expect(find.textContaining('Manage Banks & Cards'), findsWidgets);
  });

  testWidgets('a stopped import says so', (tester) async {
    await tester.pumpWidget(
      _host(
        (context) => showBulkImportSummary(
          context,
          const BulkImportResult(scanned: 12, saved: 1, cancelled: true),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Import stopped'), findsOneWidget);
  });
}
