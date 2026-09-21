/// Transaction kind. Values mirror the backend `TransactionType` enum.
enum TxType {
  income('income'),
  expense('expense'),
  transfer('transfer');

  const TxType(this.value);

  final String value;

  static TxType fromValue(String value) =>
      values.firstWhere((t) => t.value == value, orElse: () => TxType.expense);
}

/// A single transaction row from `GET /api/transactions`.
class TransactionItem {
  const TransactionItem({
    required this.id,
    required this.messageId,
    this.bankId,
    this.bankName,
    this.bankAccountType,
    required this.sender,
    required this.normalizedAmount,
    required this.normalizedCurrency,
    this.originalAmount,
    this.originalCurrency,
    required this.type,
    required this.date,
    this.pairedWithId,
    this.pairedWithMessageId,
    this.billId,
  });

  final int id;
  final int messageId;
  final int? bankId;
  final String? bankName;

  /// `"deposit"` or `"credit"` for the linked bank, else null.
  final String? bankAccountType;
  final String sender;

  /// Decimal amount kept as a string for precision.
  final String normalizedAmount;
  final String normalizedCurrency;
  final String? originalAmount;
  final String? originalCurrency;
  final TxType type;
  final DateTime date;
  final int? pairedWithId;
  final int? pairedWithMessageId;
  final int? billId;

  bool get isCreditCard => bankAccountType == 'credit';

  /// Numeric magnitude for display math (sign is applied per [type]).
  double get amountValue => double.tryParse(normalizedAmount) ?? 0;

  factory TransactionItem.fromJson(Map<String, dynamic> json) =>
      TransactionItem(
        id: json['id'] as int,
        messageId: json['message_id'] as int,
        bankId: json['bank_id'] as int?,
        bankName: json['bank_name'] as String?,
        bankAccountType: json['bank_account_type'] as String?,
        sender: json['sender'] as String,
        normalizedAmount: json['normalized_amount'].toString(),
        normalizedCurrency: json['normalized_currency'] as String,
        originalAmount: json['original_amount']?.toString(),
        originalCurrency: json['original_currency'] as String?,
        type: TxType.fromValue(json['type'] as String),
        date: DateTime.parse(json['date'] as String),
        pairedWithId: json['paired_with_id'] as int?,
        pairedWithMessageId: json['paired_with_message_id'] as int?,
        billId: json['bill_id'] as int?,
      );
}
