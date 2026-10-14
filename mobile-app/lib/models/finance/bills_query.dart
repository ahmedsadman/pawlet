/// Immutable bills read for one card: pagination plus an optional lower
/// bound. Value-equal so it can key a Riverpod family without churn.
class BillsQuery {
  const BillsQuery({
    required this.bankId,
    this.page = 1,
    this.pageSize = 20,
    this.since,
  });

  final int bankId;
  final int page;
  final int pageSize;
  final DateTime? since;

  @override
  bool operator ==(Object other) =>
      other is BillsQuery &&
      other.bankId == bankId &&
      other.page == page &&
      other.pageSize == pageSize &&
      other.since == since;

  @override
  int get hashCode => Object.hash(bankId, page, pageSize, since);
}
