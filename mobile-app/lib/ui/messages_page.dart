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
  // Seeded from the pref; drives the one-time History explainer banner.
  late bool _hintSeen;

  @override
  void initState() {
    super.initState();
    _search = TextEditingController(
      text: ref.read(historyQueryProvider).search,
    );
    _hintSeen = ref.read(settingsRepositoryProvider).historyHintSeen;
  }

  void _markHintSeen() {
    if (_hintSeen) return;
    setState(() => _hintSeen = true);
    ref.read(settingsRepositoryProvider).setHistoryHintSeen(true);
  }

  Future<void> _retry(int id) async {
    await ref.read(appServicesProvider).retryMessage(id);
    if (!mounted) return;
    // The row leaves History (failure) for the Queue; refresh both views.
    ref.invalidate(historyProvider);
    ref.invalidate(queuedProvider);
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
    final query = ref.watch(historyQueryProvider);
    final history = ref.watch(historyProvider(query));
    final queuePage = queued.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(queuedProvider);
          ref.invalidate(historyProvider);
          await ref.read(processingServiceProvider).process();
        },
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            _queueSection(queuePage),
            const SizedBox(height: 8),
            _historyHeader(),
            _searchField(),
            if (!_hintSeen) ...[_hintBanner(), const SizedBox(height: 8)],
            _historyBody(history),
          ],
        ),
      ),
    );
  }

  Widget _queueSection(QueuePage? page) {
    final count = page?.total ?? 0;
    final records = page?.records ?? const <SmsRecord>[];
    final canExpand = count > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: canExpand
              ? () => setState(() => _queueExpanded = !_queueExpanded)
              : null,
          child: SectionHeader(
            'Queue',
            count: count,
            // Pure indicator now; the whole row toggles. Hidden when empty.
            action: canExpand
                ? Icon(_queueExpanded ? Icons.expand_less : Icons.expand_more)
                : null,
          ),
        ),
        if (_queueExpanded && count > 0) ...[
          ...records.map((r) => SmsTile(r)),
          if (page != null && page.totalPages > 1) _queuePagination(page),
        ],
      ],
    );
  }

  Widget _queuePagination(QueuePage page) {
    final theme = Theme.of(context);
    void go(int p) => ref.read(queuePageIndexProvider.notifier).setPage(p);
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

  Widget _historyHeader() {
    return const SectionHeader('History');
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
          hintText: 'Search by sender or message content',
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

  Widget _hintBanner() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            Icons.lightbulb_outline,
            size: 16,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'History shows your financial messages and any that failed to '
              "process. Other texts aren't kept.",
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 16),
            visualDensity: VisualDensity.compact,
            onPressed: _markHintSeen,
          ),
        ],
      ),
    );
  }

  Widget _historyBody(AsyncValue<HistoryPage> history) {
    return history.when(
      skipLoadingOnReload: true,
      loading: () => const SmsTilesSkeleton(),
      error: (e, _) => EmptyHint('Could not load history: $e'),
      data: (page) {
        if (page.records.isEmpty) {
          return const EmptyHint('No transactions or bills yet.');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...page.records.map(
              (r) => SmsTile(
                r,
                showCategory: true,
                onRetry: r.status == SmsStatus.failure
                    ? () => _retry(r.id!)
                    : null,
              ),
            ),
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
