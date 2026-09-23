import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/sms_record.dart';
import '../state/messages_providers.dart';
import '../state/providers.dart';
import 'widgets/section_header.dart';
import 'widgets/skeleton.dart';
import 'widgets/sms_tile.dart';

/// Messages tab: a collapsible Queue on top (with a live count) and a paginated,
/// searchable History of processed Transaction/Bill messages below. History
/// labels are read-only.
class MessagesPage extends ConsumerStatefulWidget {
  const MessagesPage({super.key});

  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  bool _queueExpanded = false;
  late final TextEditingController _search;
  // Debounces the history fetch so typing doesn't refetch on every keystroke.
  Timer? _debounce;
  static const _debounceDelay = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(historyQueryProvider).search,
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the search field in sync if the query is ever reset elsewhere.
    ref.listen(historyQueryProvider, (previous, next) {
      if (next.search != _search.text) _search.text = next.search;
    });

    final queued = ref.watch(queuedProvider);
    final failedCount = ref.watch(failedCountProvider).value ?? 0;
    final query = ref.watch(historyQueryProvider);
    final history = ref.watch(historyProvider(query));
    final queuedRecords = queued.value ?? const <SmsRecord>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(queuedProvider);
          ref.invalidate(failedCountProvider);
          ref.invalidate(historyProvider);
          await ref.read(processingServiceProvider).process();
        },
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _queueSection(queuedRecords),
            const SizedBox(height: 8),
            _historyHeader(failedCount),
            _searchField(),
            _historyBody(history),
          ],
        ),
      ),
    );
  }

  Widget _queueSection(List<SmsRecord> records) {
    final count = records.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          'Queue',
          count: count,
          // Expand/collapse only offered when there is something to show.
          action: count > 0
              ? IconButton(
                  tooltip: _queueExpanded ? 'Collapse' : 'Expand',
                  icon: Icon(
                    _queueExpanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  onPressed: () =>
                      setState(() => _queueExpanded = !_queueExpanded),
                )
              : null,
        ),
        if (_queueExpanded && count > 0) ...records.map((r) => SmsTile(r)),
      ],
    );
  }

  Widget _historyHeader(int failedCount) {
    return SectionHeader(
      'History',
      action: failedCount > 0
          ? IconButton(
              tooltip: 'Retry failed',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Retrying failed messages')),
                );
                await ref.read(appServicesProvider).requeueFailed();
                ref.invalidate(historyProvider);
                ref.invalidate(failedCountProvider);
              },
            )
          : null,
    );
  }

  Widget _searchField() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _search,
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 8,
          ),
          hintText: 'Search by sender',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _debounce?.cancel();
                    _search.clear();
                    ref.read(historyQueryProvider.notifier).setSearch('');
                    setState(() {});
                  },
                ),
        ),
        onChanged: (value) {
          // setState immediately so the clear button shows/hides without lag,
          // but debounce the (paginated DB) fetch behind the query.
          setState(() {});
          _debounce?.cancel();
          _debounce = Timer(_debounceDelay, () {
            ref.read(historyQueryProvider.notifier).setSearch(value);
          });
        },
      ),
    );
  }

  Widget _historyBody(AsyncValue<HistoryPage> history) {
    return history.when(
      loading: () => const SmsTilesSkeleton(),
      error: (e, _) => EmptyHint('Could not load history: $e'),
      data: (page) {
        if (page.records.isEmpty) {
          return const EmptyHint('No transactions or bills yet.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...page.records.map((r) => SmsTile(r, showCategory: true)),
            if (page.totalPages > 1) _pagination(page),
          ],
        );
      },
    );
  }

  Widget _pagination(HistoryPage page) {
    final theme = Theme.of(context);
    void go(int p) => ref.read(historyQueryProvider.notifier).setPage(p);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: page.page > 1 ? () => go(page.page - 1) : null,
          ),
          Text(
            'Page ${page.page} of ${page.totalPages}',
            style: theme.textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: page.page < page.totalPages
                ? () => go(page.page + 1)
                : null,
          ),
        ],
      ),
    );
  }
}
