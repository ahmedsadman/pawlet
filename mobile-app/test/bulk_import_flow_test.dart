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
      find.textContaining('uses only the on-device model'),
      findsOneWidget,
    );
    expect(
      find.textContaining('low confidence score will be skipped'),
      findsOneWidget,
    );
    // The ask itself must not re-state the caveats the bullets already carry,
    // nor nudge with "(recommended)".
    expect(find.textContaining('(recommended)'), findsNothing);
    expect(
      find.text(
        'Do you want Pawlet to read your existing messages and create '
        'financial records now?',
      ),
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

    // Dismiss by tapping the scrim rather than pressing a button. (Not a
    // fling: the sheet scrolls its own content, so a drag on the body scrolls
    // instead of dismissing.)
    await tester.tapAt(const Offset(10, 10));
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

  testWidgets('the offer warns about cards up front, not just after', (
    tester,
  ) async {
    await tester.pumpWidget(_host((context) => confirmBulkImport(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Adding cards before the pass is the only way card messages land on the
    // first run, so the advice has to be here and not only in the summary.
    expect(find.textContaining('Manage Banks & Cards'), findsOneWidget);
    // Says plainly that nothing is lost by skipping it.
    expect(
      find.textContaining('Transactions are recorded either way'),
      findsOneWidget,
    );
    // Auto-creation is promised for banks and explicitly withheld for cards.
    expect(find.textContaining('but never credit cards'), findsOneWidget);
  });

  testWidgets('the offer says where to run this again later', (tester) async {
    await tester.pumpWidget(_host((context) => confirmBulkImport(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Settings → Data → Import existing messages'),
      findsOneWidget,
    );
  });

  testWidgets('a failed import says so without leaking the error', (
    tester,
  ) async {
    await tester.pumpWidget(_host((context) => showBulkImportError(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text("Import couldn't finish"), findsOneWidget);
    expect(find.textContaining('has been kept'), findsOneWidget);
    expect(
      find.textContaining('carry on from where it stopped'),
      findsOneWidget,
    );
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
