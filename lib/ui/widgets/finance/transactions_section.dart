import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/transaction.dart';
import '../../../models/finance/transactions_page.dart';
import '../../../models/finance/tx_query.dart';
import '../../../state/finance_providers.dart';
import '../../../state/providers.dart';
import '../../../theme/catppuccin_theme.dart';
import '../../../utils/currency_format.dart';
import '../../../utils/date_range.dart';
import '../section_header.dart';
import '../skeleton.dart';
import 'date_range_selector.dart';
import 'finance_placeholders.dart';
import 'transaction_row.dart';
import 'type_filter.dart';

const _defaultPreset = DateRangePreset.thisMonth;
const _defaultSort = 'date-desc';
const _pageSize = 10;

const _sortOptions = {
  'date-desc': 'Newest first',
  'date-asc': 'Oldest first',
  'amount-desc': 'Highest amount',
  'amount-asc': 'Lowest amount',
};

/// Paginated, filterable transaction list with income/expense totals.
class TransactionsSection extends ConsumerStatefulWidget {
  const TransactionsSection({super.key});

  @override
  ConsumerState<TransactionsSection> createState() =>
      _TransactionsSectionState();
}

class _TransactionsSectionState extends ConsumerState<TransactionsSection> {
  late DateRangePreset _preset;
  late List<TxType> _types;
  late String _sortKey;
  int _page = 1;
  int? _expandedId;
  // Rows in the last loaded page, so the loading skeleton matches the count and
  // the list doesn't jump when paging. Starts at a full page.
  int _lastCount = _pageSize;

  @override
  void initState() {
    super.initState();
    // Restore the last-used filters (defaults on first run).
    final repo = ref.read(settingsRepositoryProvider);
    _preset = DateRangePreset.fromKey(repo.txRange, fallback: _defaultPreset);
    _types = repo.txTypes.map(TxType.fromValue).toList();
    final sort = repo.txSort;
    _sortKey = _sortOptions.containsKey(sort) ? sort! : _defaultSort;
  }

  void _persistFilters() {
    final repo = ref.read(settingsRepositoryProvider);
    repo.setTxRange(_preset.key);
    repo.setTxTypes(_types.map((t) => t.value).toList());
    repo.setTxSort(_sortKey);
  }

  bool get _isDefault =>
      _preset == _defaultPreset && _types.isEmpty && _sortKey == _defaultSort;

  TxQuery get _query {
    final range = resolveDateRange(_preset);
    final parts = _sortKey.split('-');
    return TxQuery(
      page: _page,
      pageSize: _pageSize,
      from: range.from,
      to: range.to,
      types: _types,
      sortBy: parts[0],
      sortDir: parts[1],
    );
  }

  void _resetToFirstPage(VoidCallback apply) {
    setState(() {
      apply();
      _page = 1;
      _expandedId = null;
    });
    _persistFilters();
  }

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final hidden = ref.watch(balanceHiddenProvider);
    final async = ref.watch(transactionsProvider(_query));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: SectionHeader('Transactions')),
            if (!_isDefault)
              TextButton.icon(
                onPressed: () => _resetToFirstPage(() {
                  _preset = _defaultPreset;
                  _types = const [];
                  _sortKey = _defaultSort;
                }),
                icon: const Icon(Icons.restart_alt, size: 16),
                label: const Text('Reset'),
              ),
          ],
        ),
        Row(
          children: [
            DateRangeSelector(
              value: _preset,
              onSelected: (p) => _resetToFirstPage(() => _preset = p),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                value: _sortKey,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final entry in _sortOptions.entries)
                    DropdownMenuItem(
                      value: entry.key,
                      child: Text(entry.value),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _resetToFirstPage(() => _sortKey = value);
                  }
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TypeFilter(
          selected: _types,
          onChanged: (types) => _resetToFirstPage(() => _types = types),
        ),
        const SizedBox(height: 12),
        async.when(
          loading: () => TransactionRowsSkeleton(count: _lastCount),
          error: (_, _) => const FinanceError('Could not load transactions.'),
          data: (result) {
            _lastCount = result.data.transactions.isEmpty
                ? _pageSize
                : result.data.transactions.length;
            return _content(result.data, currency, hidden);
          },
        ),
      ],
    );
  }

  Widget _content(TransactionsPage page, String currency, bool hidden) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Totals(page: page, currency: currency),
        const SizedBox(height: 8),
        if (page.transactions.isEmpty)
          const EmptyHint('No transactions in selected range.')
        else
          for (final tx in page.transactions)
            TransactionRow(
              tx: tx,
              currency: currency,
              // While hidden, keep rows collapsed and non-expandable so the raw
              // SMS (which contains the amount) can't be revealed.
              expanded: !hidden && _expandedId == tx.id,
              onTap: hidden
                  ? null
                  : () => setState(
                      () => _expandedId = _expandedId == tx.id ? null : tx.id,
                    ),
            ),
        if (page.totalPages > 1) _Pagination(page: page, onChange: _goToPage),
      ],
    );
  }

  void _goToPage(int page) => setState(() {
    _page = page;
    _expandedId = null;
  });
}

class _Totals extends ConsumerWidget {
  const _Totals({required this.page, required this.currency});

  final TransactionsPage page;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hidden = ref.watch(balanceHiddenProvider);
    return Row(
      children: [
        Expanded(
          child: _TotalBox(
            label: 'Income',
            value: formatMoney(
              double.tryParse(page.totals.income) ?? 0,
              currency,
              hidden: hidden,
            ),
            color: AppTheme.income,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _TotalBox(
            label: 'Expense',
            value: formatMoney(
              double.tryParse(page.totals.expense) ?? 0,
              currency,
              hidden: hidden,
            ),
            color: AppTheme.expense,
          ),
        ),
      ],
    );
  }
}

class _TotalBox extends StatelessWidget {
  const _TotalBox({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _Pagination extends StatelessWidget {
  const _Pagination({required this.page, required this.onChange});

  final TransactionsPage page;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: page.page > 1 ? () => onChange(page.page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text(
            'Page ${page.page} of ${page.totalPages}',
            style: theme.textTheme.bodyMedium,
          ),
          IconButton(
            onPressed: page.page < page.totalPages
                ? () => onChange(page.page + 1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
