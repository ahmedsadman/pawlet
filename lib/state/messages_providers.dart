import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sms_repository.dart';
import '../models/sms_record.dart';
import 'providers.dart';

/// Polls [read] immediately then every 2s, so the UI reflects writes from any
/// isolate (background SMS handler, WorkManager) without manual refresh.
Stream<T> _poll<T>(Future<T> Function() read) async* {
  yield await read();
  yield* Stream.periodic(const Duration(seconds: 2)).asyncMap((_) => read());
}

/// Whether the Messages tab is the active tab. Polling only runs while it is —
/// the RootShell keeps every tab mounted in an IndexedStack, so autoDispose
/// alone would otherwise poll forever in the background.
bool _messagesActive(Ref ref) =>
    ref.watch(selectedTabProvider) == kMessagesTabIndex;

/// Queued + in-flight records (the collapsible Queue section).
final queuedProvider = StreamProvider.autoDispose<List<SmsRecord>>((ref) {
  final repo = ref.watch(smsRepositoryProvider);
  return _messagesActive(ref)
      ? _poll(repo.queued)
      : Stream.fromFuture(repo.queued()); // one snapshot, no background polling
});

/// Number of records that exhausted their retries (drives the retry affordance).
final failedCountProvider = StreamProvider.autoDispose<int>((ref) {
  final repo = ref.watch(smsRepositoryProvider);
  return _messagesActive(ref)
      ? _poll(repo.countFailed)
      : Stream.fromFuture(repo.countFailed());
});

/// Immutable History query: page (1-based) + sender search text.
class HistoryQuery {
  const HistoryQuery({this.page = 1, this.search = ''});

  final int page;
  final String search;

  HistoryQuery copyWith({int? page, String? search}) =>
      HistoryQuery(page: page ?? this.page, search: search ?? this.search);

  @override
  bool operator ==(Object other) =>
      other is HistoryQuery && other.page == page && other.search == search;

  @override
  int get hashCode => Object.hash(page, search);
}

/// A page of processed (Transaction/Bill) History rows.
class HistoryPage {
  const HistoryPage({
    required this.records,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<SmsRecord> records;
  final int total;
  final int page;
  final int pageSize;

  int get totalPages =>
      pageSize <= 0 ? 1 : (total / pageSize).ceil().clamp(1, 1 << 30);
}

/// Holds the current History query; changing the search resets to page 1.
class HistoryQueryController extends Notifier<HistoryQuery> {
  @override
  HistoryQuery build() => const HistoryQuery();

  void setSearch(String value) =>
      state = state.copyWith(page: 1, search: value.trim());

  void setPage(int page) => state = state.copyWith(page: page);
}

final historyQueryProvider =
    NotifierProvider<HistoryQueryController, HistoryQuery>(
      HistoryQueryController.new,
    );

final historyProvider = FutureProvider.autoDispose
    .family<HistoryPage, HistoryQuery>((ref, query) async {
      final repo = ref.watch(smsRepositoryProvider);
      final search = query.search.isEmpty ? null : query.search;
      final total = await repo.historyCount(query: search);
      // Clamp the requested page so a shrunk result set can't render a
      // false-empty page beyond the last one.
      final lastPage = total == 0 ? 1 : ((total - 1) ~/ kHistoryPageSize) + 1;
      final page = query.page.clamp(1, lastPage);
      final records = await repo.history(
        limit: kHistoryPageSize,
        offset: (page - 1) * kHistoryPageSize,
        query: search,
      );
      return HistoryPage(
        records: records,
        total: total,
        page: page,
        pageSize: kHistoryPageSize,
      );
    });
