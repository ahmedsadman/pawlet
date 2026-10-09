import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/services/app_services.dart';
import 'package:pawlet/state/messages_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/messages_page.dart';
import 'package:pawlet/ui/widgets/sms_tile.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAppServices extends Mock implements AppServices {}

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
const _emptyQueue = QueuePage(records: [], total: 0, page: 1, pageSize: 20);

List<Override> _overrides({
  QueuePage queue = _emptyQueue,
  HistoryPage history = _emptyHistory,
}) => [
  queuedProvider.overrideWith((ref) => Stream.value(queue)),
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
        queue: QueuePage(
          records: [
            _sms('BankA', SmsStatus.queued),
            _sms('BankB', SmsStatus.queued),
          ],
          total: 2,
          page: 1,
          pageSize: 20,
        ),
      ),
    );

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // count badge
    expect(find.text('BankA'), findsNothing); // collapsed

    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.text('BankA'), findsOneWidget);
  });

  testWidgets('tapping the Queue header row expands it', (tester) async {
    await _pump(
      tester,
      _overrides(
        queue: QueuePage(
          records: [
            _sms('BankA', SmsStatus.queued),
            _sms('BankB', SmsStatus.queued),
          ],
          total: 2,
          page: 1,
          pageSize: 20,
        ),
      ),
    );

    // Collapsed: queued rows not shown yet.
    expect(find.byType(SmsTile), findsNothing);

    // Tap the header text (not the caret) — whole row should toggle.
    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.byType(SmsTile), findsWidgets);
  });

  testWidgets('no expand control when the queue is empty', (tester) async {
    await _pump(tester, _overrides());
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
    await _pump(
      tester,
      _overrides(
        queue: QueuePage(
          records: [_sms('A', SmsStatus.queued)],
          total: 1,
          page: 1,
          pageSize: 20,
        ),
      ),
    );
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

  testWidgets('a failed history row exposes a per-row retry icon', (
    tester,
  ) async {
    final page = HistoryPage(
      records: [_sms('BRAC', SmsStatus.failure)],
      total: 1,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, _overrides(history: page));
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('an ignored history row shows Ignored and no retry icon', (
    tester,
  ) async {
    final page = HistoryPage(
      records: [_sms('EBL', SmsStatus.ignored)],
      total: 1,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, _overrides(history: page));
    expect(find.text('EBL'), findsOneWidget);
    expect(find.text('Ignored'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets('the History header no longer has a global retry button', (
    tester,
  ) async {
    // Only financial rows in history -> no failure row -> no refresh icon at all,
    // even when there are failures counted elsewhere.
    final page = HistoryPage(
      records: [_sms('BRAC', SmsStatus.success, category: 'transaction')],
      total: 1,
      page: 1,
      pageSize: 20,
    );
    await _pump(tester, _overrides(history: page));
    expect(find.byIcon(Icons.refresh), findsNothing);
  });

  testWidgets(
    'tapping a failed row retry icon calls retryMessage with its id',
    (tester) async {
      final fake = _FakeAppServices();
      when(() => fake.retryMessage(any())).thenAnswer((_) async {});

      final failed = _sms('BRAC', SmsStatus.failure);
      final page = HistoryPage(
        records: [failed],
        total: 1,
        page: 1,
        pageSize: 20,
      );
      await _pump(tester, [
        ..._overrides(history: page),
        appServicesProvider.overrideWithValue(fake),
      ]);

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump(); // let the async _retry run
      await tester.pump(const Duration(milliseconds: 50));

      verify(() => fake.retryMessage(failed.id!)).called(1);
    },
  );

  testWidgets('empty queue still shows a zero count badge', (tester) async {
    await _pump(tester, _overrides());
    expect(find.text('0'), findsOneWidget);
  });

  testWidgets('queue paginates when expanded and multi-page', (tester) async {
    await _pump(
      tester,
      _overrides(
        queue: QueuePage(
          records: [_sms('Q0', SmsStatus.queued)],
          total: 40,
          page: 1,
          pageSize: 20,
        ),
      ),
    );
    // Expand the queue to reveal its pager (history is empty, so the only
    // "Page X of Y" on screen belongs to the queue).
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pump();
    expect(find.text('Page 1 of 2'), findsOneWidget);
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
      queuedProvider.overrideWith((ref) => Stream.value(_emptyQueue)),
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
    await _pump(tester, _overrides(), prefs: {'history_hint_seen_v2': true});
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
