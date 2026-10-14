import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/finance/bank.dart';
import '../models/finance/bills_query.dart';
import '../state/finance_providers.dart';
import 'widgets/finance/bill_row.dart';
import 'widgets/finance/bill_sheet.dart';
import 'widgets/finance/finance_placeholders.dart';
import 'widgets/pagination_bar.dart';
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
    final async = ref.watch(
      billsProvider(
        BillsQuery(bankId: widget.bank.id, page: _page, pageSize: _pageSize),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: Text(widget.bank.name)),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SingleChildScrollView(
          padding: EdgeInsets.all(16),
          child: TransactionRowsSkeleton(count: _pageSize),
        ),
        error: (_, _) => const Padding(
          padding: EdgeInsets.all(16),
          child: FinanceError('Could not load bills.'),
        ),
        data: (result) {
          final page = result.data;
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              for (final bill in page.bills) ...[
                BillRow(
                  bill: bill,
                  currency: currency,
                  onLongPress: () => showBillSheet(context, ref, bill),
                ),
                const Divider(height: 1),
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
