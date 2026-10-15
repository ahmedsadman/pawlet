import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/finance_repository.dart';
import '../models/finance/bank.dart';
import '../models/finance/bills_page.dart';
import '../models/finance/bills_query.dart';
import '../models/finance/sms_message.dart';
import '../models/finance/summary.dart';
import '../models/finance/transaction.dart';
import '../models/finance/trends.dart';
import '../models/finance/transactions_page.dart';
import '../models/finance/tx_query.dart';
import '../services/finance/bill_actions.dart';
import '../utils/date_range.dart';
import 'providers.dart';

final banksProvider = FutureProvider.autoDispose<CachedResult<List<Bank>>>((
  ref,
) {
  ref.watch(dataRevisionProvider);
  return ref.watch(financeRepositoryProvider).banks();
});

final currencyProvider = FutureProvider.autoDispose<CachedResult<String>>((
  ref,
) {
  ref.watch(dataRevisionProvider);
  return ref.watch(financeRepositoryProvider).currency();
});

final trendsProvider = FutureProvider.autoDispose<CachedResult<Trends>>((ref) {
  ref.watch(dataRevisionProvider);
  return ref.watch(financeRepositoryProvider).trends();
});

final summaryProvider = FutureProvider.autoDispose
    .family<CachedResult<Summary>, DateRange>((ref, range) {
      ref.watch(dataRevisionProvider);
      return ref.watch(financeRepositoryProvider).summary(range);
    });

final transactionsProvider = FutureProvider.autoDispose
    .family<CachedResult<TransactionsPage>, TxQuery>((ref, query) {
      ref.watch(dataRevisionProvider);
      return ref.watch(financeRepositoryProvider).transactions(query);
    });

final billsProvider = FutureProvider.autoDispose
    .family<CachedResult<BillsPage>, BillsQuery>((ref, query) {
      ref.watch(dataRevisionProvider);
      return ref
          .watch(financeRepositoryProvider)
          .bills(query.bankId, page: query.page, pageSize: query.pageSize);
    });

/// A bill's linked payment legs, oldest first.
final billTransactionsProvider = FutureProvider.autoDispose
    .family<List<TransactionItem>, int>((ref, billId) {
      ref.watch(dataRevisionProvider);
      return ref.watch(financeRepositoryProvider).billTransactions(billId);
    });

final billActionsProvider = Provider<BillActions>(
  (ref) => BillActions(ref.watch(databaseProvider)),
);

// Deliberately does NOT watch dataRevisionProvider: a message's stored content
// (sender/body/timestamp) is immutable after write, so re-reading it on a bump
// would only flash the detail skeleton with no data change.
final messageProvider = FutureProvider.autoDispose
    .family<CachedResult<ApiMessage>, int>(
      (ref, id) => ref.watch(financeRepositoryProvider).message(id),
    );

/// Invalidates every finance provider so a pull-to-refresh (or a bank edit)
/// reloads all data app-wide. Calling `invalidate` on a family clears all its
/// instances.
void refreshAllFinance(WidgetRef ref) {
  ref.invalidate(banksProvider);
  ref.invalidate(currencyProvider);
  ref.invalidate(trendsProvider);
  ref.invalidate(summaryProvider);
  ref.invalidate(transactionsProvider);
  ref.invalidate(billsProvider);
  ref.invalidate(billTransactionsProvider);
  ref.invalidate(messageProvider);
}

/// Whether the one-time "long-press a bill" hint is retired. Shared rather
/// than widget-local because the bill history page can retire it too.
class BillHintSeen extends Notifier<bool> {
  @override
  bool build() => ref.watch(settingsRepositoryProvider).billActionsHintSeen;

  Future<void> markSeen() async {
    if (state) return;
    state = true;
    await ref.read(settingsRepositoryProvider).setBillActionsHintSeen(true);
  }
}

final billHintSeenProvider = NotifierProvider<BillHintSeen, bool>(
  BillHintSeen.new,
);
