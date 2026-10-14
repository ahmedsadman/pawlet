import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../models/finance/bill.dart';
import '../../../models/finance/bills_query.dart';
import '../../../state/finance_providers.dart';
import '../../../utils/date_range.dart';
import '../../bill_history_page.dart';
import '../hint_banner.dart';
import '../section_header.dart';
import '../skeleton.dart';
import 'bill_row.dart';
import 'bill_sheet.dart';

// The window's bills fit one page: a card gets about one bill a month.
const _windowPageSize = 100;

BillsQuery _billsQuery(Bank bank) => BillsQuery(
  bankId: bank.id,
  pageSize: _windowPageSize,
  since: billsWindowStart(DateTime.now()),
);

/// Per credit-card bills from the last 12 months (see [billsWindowStart]).
/// Each card shows its latest bill by default; tapping the card header reveals
/// the rest of the window, and "View more" opens the card's full history when
/// it has older bills. Long-press a bill for its SMS and the paid/unpaid
/// action. Hidden entirely when the user has no credit cards.
class CreditCardBillsSection extends ConsumerWidget {
  const CreditCardBillsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final banksAsync = ref.watch(banksProvider);
    final banks = banksAsync.value?.data;
    if (banks == null) {
      // Reserve the section with a skeleton while banks load so it doesn't pop
      // in and shove the rest of the page down when data arrives.
      return banksAsync.isLoading
          ? const CreditCardBillsSkeleton()
          : const SizedBox.shrink();
    }
    final creditCards = banks.where((b) => b.isCredit).toList();
    if (creditCards.isEmpty) return const SizedBox.shrink();
    final hintSeen = ref.watch(billHintSeenProvider);
    final anyBills = creditCards.any(
      (bank) =>
          ref
              .watch(billsProvider(_billsQuery(bank)))
              .value
              ?.data
              .bills
              .isNotEmpty ??
          false,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Credit Card Bills'),
        Card(
          child: Column(
            children: [
              if (!hintSeen && anyBills)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: HintBanner(
                    'Tip: long-press a bill to see its SMS or mark it '
                    'paid/unpaid.',
                    onDismiss: () =>
                        ref.read(billHintSeenProvider.notifier).markSeen(),
                  ),
                ),
              for (var i = 0; i < creditCards.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _BankBills(
                  key: ValueKey(creditCards[i].id),
                  bank: creditCards[i],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BankBills extends ConsumerStatefulWidget {
  const _BankBills({super.key, required this.bank});

  final Bank bank;

  @override
  ConsumerState<_BankBills> createState() => _BankBillsState();
}

class _BankBillsState extends ConsumerState<_BankBills> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final query = _billsQuery(widget.bank);
    final async = ref.watch(billsProvider(query));
    final older =
        ref
            .watch(
              olderBillCountProvider((
                bankId: widget.bank.id,
                before: query.since!,
              )),
            )
            .value ??
        0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: async.when(
        skipLoadingOnReload: true,
        loading: () =>
            _header(theme, trailing: const Skeleton(width: 56, height: 12)),
        error: (_, _) => _header(theme, subtitle: 'Could not load bills.'),
        data: (result) {
          final bills = result.data.bills;
          if (bills.isEmpty) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(
                  theme,
                  subtitle: older > 0
                      ? 'No bills in the last 12 months.'
                      : 'No bills yet.',
                ),
                if (older > 0) _viewMore(),
              ],
            );
          }
          final rest = bills.skip(1).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: rest.isEmpty
                    ? null
                    : () => setState(() => _expanded = !_expanded),
                child: _header(
                  theme,
                  trailing: rest.isEmpty
                      ? null
                      : AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: Icon(
                            Icons.expand_more,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                ),
              ),
              _row(bills.first, currency),
              if (_expanded)
                for (final bill in rest) _row(bill, currency),
              if (older > 0) _viewMore(),
            ],
          );
        },
      ),
    );
  }

  Widget _row(Bill bill, String currency) => BillRow(
    bill: bill,
    currency: currency,
    onLongPress: () => showBillSheet(context, ref, bill),
  );

  Widget _viewMore() => Align(
    alignment: Alignment.centerLeft,
    child: TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BillHistoryPage(bank: widget.bank),
        ),
      ),
      child: const Text('View more'),
    ),
  );

  Widget _header(ThemeData theme, {Widget? trailing, String? subtitle}) {
    return Row(
      children: [
        Icon(Icons.receipt_long_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.bank.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}
