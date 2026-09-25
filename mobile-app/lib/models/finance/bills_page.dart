import 'bill.dart';

/// A page of bills from `GET /api/bills`.
class BillsPage {
  const BillsPage({
    required this.bills,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  final List<Bill> bills;
  final int total;
  final int page;
  final int pageSize;

  factory BillsPage.fromJson(Map<String, dynamic> json) => BillsPage(
    bills: (json['bills'] as List)
        .map((e) => Bill.fromJson(e as Map<String, dynamic>))
        .toList(),
    total: json['total'] as int,
    page: json['page'] as int,
    pageSize: json['page_size'] as int,
  );
}
