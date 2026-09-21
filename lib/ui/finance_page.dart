import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/finance_providers.dart';
import '../state/providers.dart';
import 'widgets/finance/credit_card_bills_section.dart';
import 'widgets/finance/summary_graph_card.dart';
import 'widgets/finance/total_balance_card.dart';
import 'widgets/finance/transactions_section.dart';
import 'widgets/finance/trends_card.dart';

/// The Finance tab: balances, credit-card bills, stats, summary graph and
/// transactions. Read-only and served entirely from the local database.
/// When no banks exist yet, the Total Balance card shows an Add Bank CTA.
class FinancePage extends ConsumerStatefulWidget {
  const FinancePage({super.key});

  @override
  ConsumerState<FinancePage> createState() => _FinancePageState();
}

class _FinancePageState extends ConsumerState<FinancePage> {
  Future<void> _refresh() async {
    refreshAllFinance(ref);
    // Await one provider so the indicator lingers until data settles; swallow
    // errors so a failed refresh doesn't throw out of the RefreshIndicator.
    try {
      await ref.read(banksProvider.future);
    } catch (_) {
      // Sections render their own error state.
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(balanceHiddenProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Finance'),
        actions: [
          IconButton(
            tooltip: hidden ? 'Show balances' : 'Hide balances',
            icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => ref.read(balanceHiddenProvider.notifier).toggle(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        // A non-lazy Column (not a ListView) keeps every top card mounted so
        // their autoDispose providers stay subscribed. Content is bounded
        // (10 tx/page) so eager build is fine. AlwaysScrollable keeps
        // pull-to-refresh working when the content is short.
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TotalBalanceCard(),
              SizedBox(height: 8),
              TrendsCard(),
              SizedBox(height: 8),
              CreditCardBillsSection(),
              SizedBox(height: 8),
              SummaryGraphCard(),
              SizedBox(height: 8),
              TransactionsSection(),
            ],
          ),
        ),
      ),
    );
  }
}
