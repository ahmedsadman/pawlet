/// Immutable bills read for one card: its pagination. Value-equal so it can
/// key a Riverpod family without churn.
class BillsQuery {
  const BillsQuery({required this.bankId, this.page = 1, this.pageSize = 20});

  final int bankId;
  final int page;
  final int pageSize;

  @override
  bool operator ==(Object other) =>
      other is BillsQuery &&
      other.bankId == bankId &&
      other.page == page &&
      other.pageSize == pageSize;

  @override
  int get hashCode => Object.hash(bankId, page, pageSize);
}
