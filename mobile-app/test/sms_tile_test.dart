import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/widgets/sms_tile.dart';

SmsRecord _rec({
  SmsStatus status = SmsStatus.queued,
  String? category,
  String? lastError,
  FailureReason? failureReason,
  int attempts = 0,
  int? nextAttemptAt,
  ParseSource? parseSource,
  TxType? transactionType,
}) => SmsRecord(
  id: 1,
  sender: 'BRAC',
  content: 'debit 50 BDT',
  timestamp: DateTime(2026, 1, 2, 15, 30).millisecondsSinceEpoch,
  status: status,
  category: category,
  lastError: lastError,
  failureReason: failureReason,
  attempts: attempts,
  nextAttemptAt: nextAttemptAt,
  parseSource: parseSource,
  transactionType: transactionType,
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

  testWidgets('history tile shows Today with the time', (tester) async {
    // _rec is timestamped 2 Jan 2026 15:30 local.
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'transaction'),
        showCategory: true,
        now: () => DateTime(2026, 1, 2, 16, 0).millisecondsSinceEpoch,
      ),
    );
    expect(find.text('Today · 3:30 PM'), findsOneWidget);
  });

  testWidgets('history tile shows Yesterday on the next calendar day', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'transaction'),
        showCategory: true,
        now: () => DateTime(2026, 1, 3, 9, 0).millisecondsSinceEpoch,
      ),
    );
    expect(find.text('Yesterday · 3:30 PM'), findsOneWidget);
  });

  testWidgets('queue tile shows day and month for older messages', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.queued),
        now: () => DateTime(2026, 3, 1, 9, 0).millisecondsSinceEpoch,
      ),
    );
    expect(find.text('2 Jan · 3:30 PM'), findsOneWidget);
  });

  testWidgets('history tile shows a muted LLM badge when LLM-parsed', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(
          status: SmsStatus.success,
          category: 'transaction',
          parseSource: ParseSource.llm,
        ),
        showCategory: true,
      ),
    );
    expect(find.text('LLM'), findsOneWidget);
    expect(find.text('Transaction'), findsOneWidget);
  });

  testWidgets('locally-parsed history tile shows no LLM badge', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(
          status: SmsStatus.success,
          category: 'transaction',
          parseSource: ParseSource.local,
        ),
        showCategory: true,
      ),
    );
    expect(find.text('LLM'), findsNothing);
    expect(find.text('Transaction'), findsOneWidget);
  });

  testWidgets('LLM badge does not show in the queue (no category)', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(_rec(status: SmsStatus.sending, parseSource: ParseSource.llm)),
    );
    expect(find.text('LLM'), findsNothing);
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

  testWidgets('history transaction shows its subcategory (type) label', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(
          status: SmsStatus.success,
          category: 'transaction',
          transactionType: TxType.income,
        ),
        showCategory: true,
      ),
    );
    // Type replaces the generic "Transaction" label.
    expect(find.text('Income'), findsOneWidget);
    expect(find.text('Transaction'), findsNothing);
  });

  testWidgets(
    'history transaction with unknown type falls back to Transaction',
    (tester) async {
      await _pump(
        tester,
        SmsTile(
          _rec(status: SmsStatus.success, category: 'transaction'),
          showCategory: true,
        ),
      );
      expect(find.text('Transaction'), findsOneWidget);
    },
  );

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

  testWidgets('queue mode does not show the raw internal error', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.queued, attempts: 1, lastError: 'rate limited'),
      ),
    );
    expect(find.text('rate limited'), findsNothing);
  });

  testWidgets('queue tile shows the retry counter after a failed attempt', (
    tester,
  ) async {
    await _pump(tester, SmsTile(_rec(status: SmsStatus.queued, attempts: 2)));
    expect(find.textContaining('Retry 2/10'), findsOneWidget);
  });

  testWidgets('fresh queued tile shows no retry line', (tester) async {
    await _pump(tester, SmsTile(_rec(status: SmsStatus.queued, attempts: 0)));
    expect(find.textContaining('Retry'), findsNothing);
    expect(find.textContaining('Next attempt'), findsNothing);
  });

  testWidgets('queue tile shows the next-attempt time when it is upcoming', (
    tester,
  ) async {
    final future = DateTime(2026, 1, 2, 15, 45).millisecondsSinceEpoch;
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.queued, attempts: 2, nextAttemptAt: future),
        now: () => DateTime(2026, 1, 2, 15, 30).millisecondsSinceEpoch,
      ),
    );
    expect(find.textContaining('Next attempt at 3:45 PM'), findsOneWidget);
  });

  testWidgets('queue tile hides the next-attempt time once it is overdue', (
    tester,
  ) async {
    final scheduled = DateTime(2026, 1, 2, 15, 45).millisecondsSinceEpoch;
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.queued, attempts: 2, nextAttemptAt: scheduled),
        now: () => DateTime(2026, 1, 2, 16, 0).millisecondsSinceEpoch,
      ),
    );
    expect(find.textContaining('Retry 2/10'), findsOneWidget);
    expect(find.textContaining('Next attempt'), findsNothing);
  });

  testWidgets('history failure shows the extraction-error hint', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.failure, failureReason: FailureReason.llmError),
        showCategory: true,
      ),
    );
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('Extraction error'), findsOneWidget);
  });

  testWidgets('history failure shows the retries-exhausted hint', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(
          status: SmsStatus.failure,
          failureReason: FailureReason.retryExhausted,
        ),
        showCategory: true,
      ),
    );
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('Retries exhausted'), findsOneWidget);
  });

  testWidgets('history failure with no reason falls back to extraction error', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(_rec(status: SmsStatus.failure), showCategory: true),
    );
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('Extraction error'), findsOneWidget);
  });

  testWidgets('history failure shows the local-only hint', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.failure, failureReason: FailureReason.localOnly),
        showCategory: true,
      ),
    );
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('On-device parsing failed'), findsOneWidget);
  });

  testWidgets('history never renders the internal last_error', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(
          status: SmsStatus.failure,
          failureReason: FailureReason.llmError,
          lastError: 'secret internal detail',
        ),
        showCategory: true,
      ),
    );
    expect(find.text('secret internal detail'), findsNothing);
  });

  testWidgets('failed history row shows a retry icon that fires onRetry', (
    tester,
  ) async {
    var tapped = 0;
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.failure, failureReason: FailureReason.llmError),
        showCategory: true,
        onRetry: () => tapped++,
      ),
    );
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('failed history row without onRetry shows no retry icon', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.failure, failureReason: FailureReason.llmError),
        showCategory: true,
      ),
    );
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('successful history row shows no retry icon', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'transaction'),
        showCategory: true,
        onRetry: () {},
      ),
    );
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('history tile hides the message body until tapped', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.success, category: 'transaction'),
        showCategory: true,
      ),
    );
    // Compact: body hidden, caret shown.
    expect(find.text('debit 50 BDT'), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);

    // Tap anywhere on the card.
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();

    expect(find.text('debit 50 BDT'), findsOneWidget);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);

    // Tap again to collapse.
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('debit 50 BDT'), findsNothing);
  });

  testWidgets('queue tile still shows the body inline (not compact)', (
    tester,
  ) async {
    await _pump(tester, SmsTile(_rec(status: SmsStatus.queued)));
    expect(find.text('debit 50 BDT'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
  });

  testWidgets('history failure hint is revealed on expand', (tester) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.failure, failureReason: FailureReason.llmError),
        showCategory: true,
      ),
    );
    // Hint lives in the collapsible body now.
    expect(find.text('Extraction error'), findsNothing);
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('Extraction error'), findsOneWidget);
  });

  testWidgets('ignored history row shows the grey Ignored badge only', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.ignored, parseSource: ParseSource.llm),
        showCategory: true,
        onRetry: () {},
      ),
    );
    expect(find.text('Ignored'), findsOneWidget);
    expect(find.text('LLM'), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);

    // Expands like any other row: the message, no failure hint.
    await tester.tap(find.text('BRAC'));
    await tester.pumpAndSettle();
    expect(find.text('debit 50 BDT'), findsOneWidget);
    expect(find.text('Extraction error'), findsNothing);
  });

  testWidgets('ignored history row never shows a category label', (
    tester,
  ) async {
    await _pump(
      tester,
      SmsTile(
        _rec(status: SmsStatus.ignored, category: 'transaction'),
        showCategory: true,
      ),
    );
    expect(find.text('Ignored'), findsOneWidget);
    expect(find.text('Transaction'), findsNothing);
  });
}
