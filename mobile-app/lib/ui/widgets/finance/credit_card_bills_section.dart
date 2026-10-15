import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../models/finance/bank.dart';
import '../../../models/finance/bill.dart';
import '../../../models/finance/bills_query.dart';
import '../../../state/finance_providers.dart';
import '../../bill_history_page.dart';
import '../hint_banner.dart';
import '../section_header.dart';
import '../skeleton.dart';
import 'bill_row.dart';
import 'bill_sheet.dart';

/// How many of a card's most recent bills the section shows.
const _latestBillCount = 12;

/// Expand/collapse timing, shared by the bill rows and the header chevron.
const _expandDuration = Duration(milliseconds: 250);
const _expandCurve = Curves.easeInOut;

BillsQuery _billsQuery(Bank bank) =>
    BillsQuery(bankId: bank.id, pageSize: _latestBillCount);

/// Per credit-card bills: each card's 12 most recent. A card shows its latest
/// bill by default; tapping its header reveals the rest (one card open at a
/// time), plus "View more" to the card's full history when it has more than
/// 12 bills. Long-press a bill for its SMS and the paid/unpaid action. Hidden
/// entirely when the user has no credit cards.
class CreditCardBillsSection extends ConsumerStatefulWidget {
  const CreditCardBillsSection({super.key});

  @override
  ConsumerState<CreditCardBillsSection> createState() =>
      _CreditCardBillsSectionState();
}

class _CreditCardBillsSectionState
    extends ConsumerState<CreditCardBillsSection> {
  /// The one card whose bill list is open, if any.
  int? _expandedBankId;

  /// One key per card, to find where it sits on screen.
  final _cardKeys = <int, GlobalKey<_BankBillsState>>{};

  /// While the open card collapses above the tapped one, the tapped card's
  /// offset from the top of the scroll viewport, held there until both settle.
  ({int bankId, double top, ScrollPosition position, RenderBox viewport})?
  _anchor;

  void _toggle(int bankId, List<Bank> cards) {
    _anchor = null;
    final open = cards.indexWhere((b) => b.id == _expandedBankId);
    // Switching to a card below the open one: the collapse above would shove
    // the tapped card up, maybe off screen, so pin it where it was tapped.
    if (open != -1 && open < cards.indexWhere((b) => b.id == bankId)) {
      final scrollable = Scrollable.maybeOf(context);
      final viewport = scrollable?.context.findRenderObject();
      final top = viewport is RenderBox ? _topIn(viewport, bankId) : null;
      if (viewport is RenderBox && top != null) {
        _anchor = (
          bankId: bankId,
          top: top,
          position: scrollable!.position,
          viewport: viewport,
        );
      }
    }
    setState(() => _expandedBankId = _expandedBankId == bankId ? null : bankId);
  }

  double? _topIn(RenderBox viewport, int bankId) {
    final box = _cardKeys[bankId]?.currentContext?.findRenderObject();
    return box is RenderBox
        ? box.localToGlobal(Offset.zero, ancestor: viewport).dy
        : null;
  }

  // Runs after the section lays out but before paint, so the scroll moves in
  // the same frame as the drift and the anchored card never visibly jumps.
  // The viewport clamps the corrected offset to its extents right after.
  void _keepAnchored() {
    final anchor = _anchor;
    if (anchor == null) return;
    final top = _topIn(anchor.viewport, anchor.bankId);
    if (top != null) anchor.position.correctBy(top - anchor.top);
    final animating = _cardKeys.values.any(
      (key) => key.currentState?._controller.isAnimating ?? false,
    );
    if (!animating) _anchor = null;
  }

  @override
  Widget build(BuildContext context) {
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
        _AfterLayout(
          onLayout: _keepAnchored,
          child: Card(
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
                    key: _cardKeys.putIfAbsent(
                      creditCards[i].id,
                      GlobalKey<_BankBillsState>.new,
                    ),
                    bank: creditCards[i],
                    expanded: _expandedBankId == creditCards[i].id,
                    onToggle: () => _toggle(creditCards[i].id, creditCards),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Calls [onLayout] right after [child] lays out, before anything paints.
class _AfterLayout extends SingleChildRenderObjectWidget {
  const _AfterLayout({required this.onLayout, super.child});

  final VoidCallback onLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderAfterLayout(onLayout);

  @override
  void updateRenderObject(BuildContext context, _RenderAfterLayout render) =>
      render.onLayout = onLayout;
}

class _RenderAfterLayout extends RenderProxyBox {
  _RenderAfterLayout(this.onLayout);

  VoidCallback onLayout;

  @override
  void performLayout() {
    super.performLayout();
    onLayout();
  }
}

class _BankBills extends ConsumerStatefulWidget {
  const _BankBills({
    super.key,
    required this.bank,
    required this.expanded,
    required this.onToggle,
  });

  final Bank bank;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  ConsumerState<_BankBills> createState() => _BankBillsState();
}

class _BankBillsState extends ConsumerState<_BankBills>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _reveal;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _expandDuration,
      value: widget.expanded ? 1 : 0,
    )..addStatusListener(_onStatus);
    _reveal = CurvedAnimation(parent: _controller, curve: _expandCurve);
  }

  // Once fully collapsed, rebuild so the hidden rows leave the tree.
  void _onStatus(AnimationStatus status) {
    if (status.isDismissed && mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_BankBills oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != oldWidget.expanded) {
      widget.expanded ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currency = ref.watch(currencyProvider).value?.data ?? '';
    final async = ref.watch(billsProvider(_billsQuery(widget.bank)));

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: async.when(
        skipLoadingOnReload: true,
        loading: () =>
            _header(theme, trailing: const Skeleton(width: 56, height: 12)),
        error: (_, _) => _header(theme, subtitle: 'Could not load bills.'),
        data: (result) {
          final bills = result.data.bills;
          if (bills.isEmpty) return _header(theme, subtitle: 'No bills yet.');
          final rest = bills.skip(1).toList();
          final hasMore = result.data.total > _latestBillCount;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              InkWell(
                onTap: rest.isEmpty ? null : widget.onToggle,
                child: _header(
                  theme,
                  trailing: rest.isEmpty
                      ? null
                      : AnimatedRotation(
                          turns: widget.expanded ? 0.5 : 0,
                          duration: _expandDuration,
                          curve: _expandCurve,
                          child: Icon(
                            Icons.expand_more,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                ),
              ),
              _row(
                bills.first,
                currency,
                onTap: rest.isEmpty ? null : widget.onToggle,
              ),
              // SizeTransition clips the reveal; the rows stay built until the
              // collapse finishes so it mirrors the expand.
              if (rest.isNotEmpty && !_controller.isDismissed)
                SizeTransition(
                  sizeFactor: _reveal,
                  alignment: AlignmentDirectional.topStart,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final bill in rest) _row(bill, currency),
                      if (hasMore) _viewMore(),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(Bill bill, String currency, {VoidCallback? onTap}) => BillRow(
    bill: bill,
    currency: currency,
    onTap: onTap,
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
