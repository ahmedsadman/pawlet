import 'transaction.dart';

/// Immutable transaction query: pagination, date window, type filter, and sort.
/// Value-equal so it can key a Riverpod family without churn.
class TxQuery {
  const TxQuery({
    this.page = 1,
    this.pageSize = 10,
    this.from,
    this.to,
    this.types = const [],
    this.sortBy = 'date',
    this.sortDir = 'desc',
  });

  final int page;
  final int pageSize;
  final DateTime? from;
  final DateTime? to;
  final List<TxType> types;

  /// `"date"` or `"amount"`.
  final String sortBy;

  /// `"asc"` or `"desc"`.
  final String sortDir;

  TxQuery copyWith({
    int? page,
    int? pageSize,
    DateTime? from,
    DateTime? to,
    List<TxType>? types,
    String? sortBy,
    String? sortDir,
    bool clearDates = false,
  }) => TxQuery(
    page: page ?? this.page,
    pageSize: pageSize ?? this.pageSize,
    from: clearDates ? null : (from ?? this.from),
    to: clearDates ? null : (to ?? this.to),
    types: types ?? this.types,
    sortBy: sortBy ?? this.sortBy,
    sortDir: sortDir ?? this.sortDir,
  );

  /// Query params for `GET /api/transactions`. Dates are sent as UTC ISO-8601.
  Map<String, dynamic> toParams() => {
    'page': page,
    'page_size': pageSize,
    if (from != null) 'from_date': from!.toUtc().toIso8601String(),
    if (to != null) 'to_date': to!.toUtc().toIso8601String(),
    if (types.isNotEmpty) 'types': types.map((t) => t.value).toList(),
    'sort_by': sortBy,
    'sort_dir': sortDir,
  };

  @override
  bool operator ==(Object other) =>
      other is TxQuery &&
      other.page == page &&
      other.pageSize == pageSize &&
      other.from == from &&
      other.to == to &&
      other.sortBy == sortBy &&
      other.sortDir == sortDir &&
      _sameTypes(other.types, types);

  @override
  int get hashCode => Object.hash(
    page,
    pageSize,
    from,
    to,
    sortBy,
    sortDir,
    Object.hashAll(types),
  );

  static bool _sameTypes(List<TxType> a, List<TxType> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
