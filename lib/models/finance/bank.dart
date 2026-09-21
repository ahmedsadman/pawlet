/// A bank account (deposit) or credit card, as returned by `GET /api/banks`.
class Bank {
  const Bank({
    required this.id,
    required this.name,
    required this.accountType,
    this.cardDigits,
    this.lastBalance,
    this.lastBalanceAt,
    required this.createdAt,
  });

  final int id;
  final String name;

  /// `"deposit"` or `"credit"`.
  final String accountType;

  /// `"1234|5678"` (first4|last4) for credit cards, else null.
  final String? cardDigits;

  /// Decimal amount kept as a string for precision; null for credit cards.
  final String? lastBalance;
  final DateTime? lastBalanceAt;
  final DateTime createdAt;

  bool get isCredit => accountType == 'credit';
  bool get isDeposit => accountType == 'deposit';

  /// Last four card digits, or null when unavailable.
  String? get last4 {
    final digits = cardDigits;
    if (digits == null) return null;
    final parts = digits.split('|');
    return parts.length == 2 ? parts[1] : null;
  }

  factory Bank.fromJson(Map<String, dynamic> json) => Bank(
    id: json['id'] as int,
    name: json['name'] as String,
    accountType: json['account_type'] as String,
    cardDigits: json['card_digits'] as String?,
    lastBalance: json['last_balance']?.toString(),
    lastBalanceAt: json['last_balance_at'] == null
        ? null
        : DateTime.parse(json['last_balance_at'] as String),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}
