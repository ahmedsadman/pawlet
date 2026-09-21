/// A credit-card bill from `GET /api/bills`.
class Bill {
  const Bill({
    required this.id,
    required this.messageId,
    required this.sender,
    required this.receivedAt,
    this.bankId,
    this.bankName,
    required this.normalizedTotalDue,
    required this.normalizedCurrency,
    this.originalAmount,
    this.originalCurrency,
    this.statementPeriod,
    this.paidAt,
    this.linkedTransactionIds = const [],
    required this.createdAt,
  });

  final int id;
  final int messageId;
  final String sender;
  final DateTime receivedAt;
  final int? bankId;
  final String? bankName;

  /// Decimal amount kept as a string for precision.
  final String normalizedTotalDue;
  final String normalizedCurrency;
  final String? originalAmount;
  final String? originalCurrency;
  final DateTime? statementPeriod;
  final DateTime? paidAt;
  final List<int> linkedTransactionIds;
  final DateTime createdAt;

  bool get isPaid => paidAt != null;

  factory Bill.fromJson(Map<String, dynamic> json) => Bill(
    id: json['id'] as int,
    messageId: json['message_id'] as int,
    sender: json['sender'] as String,
    receivedAt: DateTime.parse(json['received_at'] as String),
    bankId: json['bank_id'] as int?,
    bankName: json['bank_name'] as String?,
    normalizedTotalDue: json['normalized_total_due'].toString(),
    normalizedCurrency: json['normalized_currency'] as String,
    originalAmount: json['original_amount']?.toString(),
    originalCurrency: json['original_currency'] as String?,
    statementPeriod: json['statement_period'] == null
        ? null
        : DateTime.parse(json['statement_period'] as String),
    paidAt: json['paid_at'] == null
        ? null
        : DateTime.parse(json['paid_at'] as String),
    linkedTransactionIds:
        (json['linked_transaction_ids'] as List?)?.cast<int>() ?? const [],
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
