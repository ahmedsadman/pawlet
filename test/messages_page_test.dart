import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/models/sms_record.dart';
import 'package:meowni/state/messages_providers.dart';
import 'package:meowni/state/providers.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/messages_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

SmsRecord _sms(String sender, SmsStatus status, {String? category}) =>
    SmsRecord(
      id: sender.hashCode,
      sender: sender,
      content: 'msg from $sender',
      timestamp: DateTime(2026, 1, 1).millisecondsSinceEpoch,
      status: status,
      category: category,
    );

const _emptyHistory = HistoryPage(records: [], total: 0, page: 1, pageSize: 20);

List<Override> _overrides({
  List<SmsRecord> queued = const [],
  int failed = 0,
  HistoryPage history = _emptyHistory,
}) => [
  queuedProvider.overrideWith((ref) => Stream.value(queued)),
  failedCountProvider.overrideWith((ref) => Stream.value(failed)),
  historyProvider.overrideWith((ref, q) async => history),
];

Future<void> _pump(
  WidgetTester tester,
  List<Override> overrides, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final sp = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sp),
        ...overrides,
      ],
      child: MaterialApp(theme: AppTheme.theme, home: const MessagesPage()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  testWidgets('queue is collapsed by default with a count, expands on tap', (
    tester,
  ) async {
    await _pump(
      tester,
      _overrides(
        queued: [
          _sms('BankA', SmsStatus.queued),
          _sms('BankB', SmsStatus.queued),
        ],
      ),
    );

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // count badge
    expect(find.text('BankA'), findsNothing); // collapsed

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.text('BankA'), findsOneWidget);
  });

  testWidgets('no expand control when the queue is empty', (tester) async {
    await _pump(tester, _overrides(queued: const []));
    expect(find.text('Queue'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsNothing);
    expect(find.byIcon(Icons.expand_less), findsNothing);
  });

  testWidgets('history shows read-only labels and paginates', (tester) async {
    final page = HistoryPage(
      records: [_sms('BRAC', SmsStatus.success, category: 'transaction')],
      total: 40,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, _overrides(history: page));

    expect(find.text('Transaction'), findsOneWidget);
    expect(find.text('Page 1 of 2'), findsOneWidget);
  });

  testWidgets('Queue section is above History', (tester) async {
    await _pump(tester, _overrides(queued: [_sms('A', SmsStatus.queued)]));
    expect(
      tester.getTopLeft(find.text('Queue')).dy <
          tester.getTopLeft(find.text('History')).dy,
      isTrue,
    );
  });

  testWidgets('typing in search updates the history query after the debounce', (
    tester,
  ) async {
    await _pump(tester, _overrides());
    await tester.enterText(find.byType(TextField), 'brac');
    await tester.pump();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MessagesPage)),
    );
    // Debounced: the query is not updated on the keystroke itself.
    expect(container.read(historyQueryProvider).search, '');

    await tester.pump(const Duration(milliseconds: 450));
    expect(container.read(historyQueryProvider).search, 'brac');
  });

  test('setSearch resets the page to 1', () {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    c.read(historyQueryProvider.notifier).setPage(3);
    expect(c.read(historyQueryProvider).page, 3);
    c.read(historyQueryProvider.notifier).setSearch('brac');
    expect(c.read(historyQueryProvider).page, 1);
    expect(c.read(historyQueryProvider).search, 'brac');
  });

  testWidgets('retry affordance appears when there are failures', (
    tester,
  ) async {
    await _pump(tester, _overrides(failed: 2));
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('no retry affordance when there are no failures', (tester) async {
    await _pump(tester, _overrides(failed: 0));
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('empty queue still shows a zero count badge', (tester) async {
    await _pump(tester, _overrides(queued: const []));
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('refetches history when the search query changes', (
    tester,
  ) async {
    final match = HistoryPage(
      records: [_sms('BRAC', SmsStatus.success, category: 'transaction')],
      total: 1,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, [
      queuedProvider.overrideWith((ref) => Stream.value(const <SmsRecord>[])),
      failedCountProvider.overrideWith((ref) => Stream.value(0)),
      historyProvider.overrideWith(
        (ref, q) async => q.search == 'brac' ? match : _emptyHistory,
      ),
    ]);
    expect(find.text('BRAC'), findsNothing);

    await tester.enterText(find.byType(TextField), 'brac');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450)); // past the debounce
    await tester.pump(const Duration(milliseconds: 200)); // resolve the fetch
    expect(find.text('BRAC'), findsOneWidget);
    expect(find.text('Transaction'), findsOneWidget);
  });

  testWidgets('shows the one-time History banner, dismissible', (tester) async {
    await _pump(tester, _overrides());
    expect(find.textContaining('failed to process'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.textContaining('failed to process'), findsNothing);
  });

  testWidgets('History banner stays hidden once seen', (tester) async {
    await _pump(tester, _overrides(), prefs: {'history_hint_seen': true});
    expect(find.textContaining('failed to process'), findsNothing);
  });

  testWidgets('prev is disabled on the first page, next enabled', (
    tester,
  ) async {
    final page = HistoryPage(
      records: [_sms('BRAC', SmsStatus.success, category: 'transaction')],
      total: 40,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, _overrides(history: page));
    final prev = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_left),
        matching: find.byType(IconButton),
      ),
    );
    final next = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.chevron_right),
        matching: find.byType(IconButton),
      ),
    );
    expect(prev.onPressed, isNull);
    expect(next.onPressed, isNotNull);
  });
}
