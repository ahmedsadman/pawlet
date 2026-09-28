import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'; // ScrollDirection
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/finance_providers.dart';
import '../state/providers.dart';
import 'banks_page.dart';
import 'widgets/finance/credit_card_bills_section.dart';
import 'widgets/finance/summary_graph_card.dart';
import 'widgets/finance/total_balance_card.dart';
import 'widgets/finance/transaction_entry_sheet.dart';
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
  // Drives the FAB show/hide animation.
  bool _fabVisible = true;

  Future<void> _refresh() async {
    refreshAllFinance(ref);
    try {
      await ref.read(banksProvider.future);
    } catch (_) {
      // Sections render their own error state.
    }
  }

  // Hide the FAB while scrolling down; show it while scrolling up or near the
  // top. Returns false so the notification keeps bubbling.
  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification) {
      if (n.direction == ScrollDirection.reverse && _fabVisible) {
        setState(() => _fabVisible = false);
      } else if (n.direction == ScrollDirection.forward && !_fabVisible) {
        setState(() => _fabVisible = true);
      }
    }
    if (n.metrics.pixels <= 0 && !_fabVisible) {
      setState(() => _fabVisible = true);
    }
    return false;
  }

  Future<void> _openAddMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: const Text('Transaction'),
              subtitle: const Text('Add a manual income or expense'),
              onTap: () => Navigator.of(context).pop('transaction'),
            ),
            ListTile(
              leading: const Icon(Icons.account_balance_outlined),
              title: const Text('Banks & Cards'),
              subtitle: const Text('Add or manage your accounts'),
              onTap: () => Navigator.of(context).pop('banks'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'transaction') {
      // The sheet inserts + refreshes on success; returns true when added.
      await showAddTransactionSheet(context);
    } else if (choice == 'banks') {
      // BanksPage refreshes finance itself after edits.
      await Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => const BanksPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = ref.watch(balanceHiddenProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Pawlet',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            tooltip: hidden ? 'Show balances' : 'Hide balances',
            icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
            onPressed: () => ref.read(balanceHiddenProvider.notifier).toggle(),
          ),
        ],
      ),
      floatingActionButton: AnimatedSlide(
        duration: const Duration(milliseconds: 200),
        offset: _fabVisible ? Offset.zero : const Offset(0, 2),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: _fabVisible ? 1 : 0,
          child: FloatingActionButton(
            onPressed: _openAddMenu,
            tooltip: 'Add',
            child: const Icon(Icons.add),
          ),
        ),
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: RefreshIndicator(
          onRefresh: _refresh,
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
                // Bottom padding so the FAB never covers the last row.
                SizedBox(height: 72),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
