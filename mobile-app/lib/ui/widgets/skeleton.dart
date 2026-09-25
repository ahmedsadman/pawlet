import 'package:flutter/material.dart';

import 'section_header.dart';

/// A single shimmering placeholder block. Pulses between two surface tones to
/// signal loading. Sized by the caller so each skeleton can mimic the real
/// widget it stands in for.
class Skeleton extends StatefulWidget {
  const Skeleton({
    this.width,
    this.height = 16,
    this.borderRadius = 8,
    super.key,
  });

  final double? width;
  final double height;
  final double borderRadius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Color.lerp(
            scheme.surfaceContainerHighest,
            scheme.surfaceContainerHigh,
            _controller.value,
          ),
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}

/// Chart-shaped placeholder that fills the summary graph's fixed height.
class SummaryChartSkeleton extends StatelessWidget {
  const SummaryChartSkeleton({super.key});

  @override
  Widget build(BuildContext context) =>
      const Skeleton(height: double.infinity, borderRadius: 12);
}

/// A list of transaction-row placeholders. [count] should match the number of
/// rows about to render so the layout doesn't jump when real data loads.
class TransactionRowsSkeleton extends StatelessWidget {
  const TransactionRowsSkeleton({required this.count, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < count; i++) const _TransactionRowSkeleton(),
      ],
    );
  }
}

class _TransactionRowSkeleton extends StatelessWidget {
  const _TransactionRowSkeleton();

  @override
  Widget build(BuildContext context) {
    // Mirrors TransactionRow: 10px vertical padding, a two-line body on the
    // left (sender + badges/time) and a trailing amount, then a divider.
    return Column(
      children: const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Skeleton(width: 130, height: 14),
                    SizedBox(height: 6),
                    Skeleton(width: 90, height: 12),
                  ],
                ),
              ),
              SizedBox(width: 8),
              Skeleton(width: 72, height: 14),
            ],
          ),
        ),
        Divider(height: 1),
      ],
    );
  }
}

/// Two-line placeholder for the expanded message panel inside a transaction.
class MessageLinesSkeleton extends StatelessWidget {
  const MessageLinesSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: const [
        Skeleton(width: 80, height: 10),
        SizedBox(height: 6),
        Skeleton(height: 12),
      ],
    );
  }
}

/// Placeholder for the whole Credit Card Bills section, shown while banks load
/// so the section reserves its space instead of popping in and shoving the page.
class CreditCardBillsSkeleton extends StatelessWidget {
  const CreditCardBillsSkeleton({this.cards = 2, super.key});

  final int cards;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Credit Card Bills'),
        Card(
          child: Column(
            children: [
              for (var i = 0; i < cards; i++) ...[
                if (i > 0) const Divider(height: 1),
                const _BillCardSkeleton(),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _BillCardSkeleton extends StatelessWidget {
  const _BillCardSkeleton();

  @override
  Widget build(BuildContext context) {
    // Mirrors _BankBills: 16/8 padding, an icon + bank-name header, then a
    // bill row (date on the left, amount on the right).
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Skeleton(width: 24, height: 24, borderRadius: 6),
              SizedBox(width: 12),
              Skeleton(width: 120, height: 14),
            ],
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Skeleton(width: 90, height: 12),
              Spacer(),
              Skeleton(width: 70, height: 14),
            ],
          ),
        ],
      ),
    );
  }
}

/// A list of SMS-tile placeholders for the Messages tab, matching [SmsTile]'s
/// card layout (title + status badge, content lines, timestamp).
class SmsTilesSkeleton extends StatelessWidget {
  const SmsTilesSkeleton({this.count = 3, super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [for (var i = 0; i < count; i++) const _SmsTileSkeleton()],
    );
  }
}

class _SmsTileSkeleton extends StatelessWidget {
  const _SmsTileSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Card(
      margin: EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Skeleton(width: 140, height: 14)),
                SizedBox(width: 8),
                Skeleton(width: 56, height: 18, borderRadius: 12),
              ],
            ),
            SizedBox(height: 10),
            Skeleton(height: 12),
            SizedBox(height: 6),
            Skeleton(width: 200, height: 12),
            SizedBox(height: 10),
            Skeleton(width: 120, height: 10),
          ],
        ),
      ),
    );
  }
}
