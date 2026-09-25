import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/finance_repository.dart';
import '../models/finance/bank.dart';
import '../models/finance/bills_page.dart';
import '../models/finance/sms_message.dart';
import '../models/finance/summary.dart';
import '../models/finance/trends.dart';
import '../models/finance/transactions_page.dart';
import '../models/finance/tx_query.dart';
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
    .family<CachedResult<BillsPage>, int>((ref, bankId) {
      ref.watch(dataRevisionProvider);
      return ref.watch(financeRepositoryProvider).bills(bankId);
    });

final messageProvider = FutureProvider.autoDispose
    .family<CachedResult<ApiMessage>, int>((ref, id) {
      ref.watch(dataRevisionProvider);
      return ref.watch(financeRepositoryProvider).message(id);
    });

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
  ref.invalidate(messageProvider);
}
