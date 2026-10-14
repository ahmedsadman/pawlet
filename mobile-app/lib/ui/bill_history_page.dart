import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/finance/bank.dart';
import '../models/finance/bills_query.dart';
import '../state/finance_providers.dart';
import 'widgets/finance/bill_row.dart';
import 'widgets/finance/bill_sheet.dart';
import 'widgets/finance/finance_placeholders.dart';
import 'widgets/pagination_bar.dart';
import 'widgets/section_header.dart';
import 'widgets/skeleton.dart';

const _pageSize = 10;

/// Every bill on one credit card, newest first, [_pageSize] per page. Opened
/// from the bills section's "View more". Long-press a bill for its details and
/// the paid/unpaid action.
class BillHistoryPage extends ConsumerStatefulWidget {
  const BillHistoryPage({required this.bank, super.key});

  final Bank bank;

  @override
  ConsumerState<BillHistoryPage> createState() => _BillHistoryPageState();
}

class _BillHistoryPageState extends ConsumerState<BillHistoryPage> {
  int _page = 1;

  @override
  Widget build(BuildContext context) {
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final query = BillsQuery(
      bankId: widget.bank.id,
      page: _page,
      pageSize: _pageSize,
    );
    final async = ref.watch(billsProvider(query));
    return Scaffold(
      appBar: AppBar(title: Text(widget.bank.name)),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TransactionRowsSkeleton(count: _pageSize),
        ),
        error: (_, _) => Padding(
          padding: const EdgeInsets.all(16),
          child: FinanceError(
            'Could not load bills.',
            onRetry: () => ref.invalidate(billsProvider(query)),
          ),
        ),
        data: (result) {
          final page = result.data;
          if (page.bills.isEmpty) {
            return const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: EmptyHint('No bills yet.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (var i = 0; i < page.bills.length; i++) ...[
                BillRow(
                  bill: page.bills[i],
                  currency: currency,
                  onLongPress: () => showBillSheet(context, ref, page.bills[i]),
                ),
                if (i < page.bills.length - 1) const Divider(height: 1),
              ],
              if (page.totalPages > 1)
                PaginationBar(
                  page: page.page,
                  totalPages: page.totalPages,
                  onChange: (p) => setState(() => _page = p),
                ),
            ],
          );
        },
      ),
    );
  }
}
