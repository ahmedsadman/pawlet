import 'package:decimal/decimal.dart';

import 'transaction.dart';

/// What a pairing-review card asks.
enum PairingKind {
  /// Money moved between two of the user's deposit accounts.
  transfer,

  /// A bank debit that paid a credit card.
  cardPayment,
}

/// One side of a suggested pair.
class PairingLeg {
  const PairingLeg({
    required this.id,
    required this.messageId,
    required this.bankId,
    required this.bankName,
    required this.accountType,
    this.cardDigits,
    required this.amount,
    required this.currency,
    required this.type,
    required this.date,
  });

  final int id;

  /// Null for a manual (user-entered) transaction.
  final int? messageId;
  final int bankId;
  final String bankName;

  /// `"deposit"` or `"credit"`.
  final String accountType;

  /// `"1234|5678"` (first4|last4) for credit cards, else null.
  final String? cardDigits;

  /// Normalized amount, kept as a string for precision.
  final String amount;
  final String currency;
  final TxType type;
  final DateTime date;

  bool get isCredit => accountType == 'credit';

  /// The bank name, plus the last four card digits for a credit card.
  String get label {
    final parts = cardDigits?.split('|');
    final last4 = parts != null && parts.length == 2 ? parts[1] : null;
    return isCredit && last4 != null ? '$bankName ••$last4' : bankName;
  }
}

/// A pair the user is asked to confirm.
class PairingSuggestion {
  const PairingSuggestion({
    required this.kind,
    required this.from,
    required this.to,
    this.otherMatches = 0,
  });

  final PairingKind kind;

  /// The debit: an `expense` on a deposit account.
  final PairingLeg from;

  /// The receiving side: an `income` on another deposit account
  /// ([PairingKind.transfer]) or the card's `transfer` row
  /// ([PairingKind.cardPayment]).
  final PairingLeg to;

  /// Other candidates that share a leg with this pair but were not suggested.
  final int otherMatches;

  int get lowId => from.id < to.id ? from.id : to.id;
  int get highId => from.id < to.id ? to.id : from.id;

  /// Stable identity of the pair, independent of leg order.
  String get key => '$lowId-$highId';

  Duration get gap => from.date.difference(to.date).abs();

  Decimal get amountDifference =>
      (Decimal.parse(from.amount) - Decimal.parse(to.amount)).abs();

  DateTime get newerDate => from.date.isAfter(to.date) ? from.date : to.date;
}
