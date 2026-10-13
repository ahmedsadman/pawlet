import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:pawlet/models/finance/pairing_suggestion.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/services/finance/pairing_actions.dart';
import 'package:pawlet/services/finance/pairing_suggester.dart';
import 'package:pawlet/state/pairing_providers.dart';

final _base = DateTime(2026, 10, 14, 12);

PairingLeg pairingLeg(
  int id, {
  String bank = 'MTB',
  String accountType = 'deposit',
  String? cardDigits,
  String amount = '1500',
  TxType type = TxType.expense,
  Duration ago = Duration.zero,
  int? messageId,
}) => PairingLeg(
  id: id,
  messageId: messageId,
  bankId: bank.hashCode,
  bankName: bank,
  accountType: accountType,
  cardDigits: cardDigits,
  amount: amount,
  currency: 'BDT',
  type: type,
  date: _base.subtract(ago),
);

/// A transfer suggestion: MTB out -> City in, two hours apart.
PairingSuggestion transferSuggestion(
  int fromId,
  int toId, {
  String fromAmount = '1510',
  String toAmount = '1500',
  int otherMatches = 0,
  int? fromMessage,
  int? toMessage,
}) => PairingSuggestion(
  kind: PairingKind.transfer,
  from: pairingLeg(
    fromId,
    amount: fromAmount,
    ago: const Duration(hours: 2),
    messageId: fromMessage,
  ),
  to: pairingLeg(
    toId,
    bank: 'City Bank',
    amount: toAmount,
    type: TxType.income,
    messageId: toMessage,
  ),
  otherMatches: otherMatches,
);

/// A card-payment suggestion: DBBL debit -> EBL card, a day apart.
PairingSuggestion cardSuggestion(int fromId, int toId) => PairingSuggestion(
  kind: PairingKind.cardPayment,
  from: pairingLeg(
    fromId,
    bank: 'DBBL',
    amount: '2951',
    ago: const Duration(days: 1, hours: 3),
  ),
  to: pairingLeg(
    toId,
    bank: 'EBL',
    accountType: 'credit',
    cardDigits: '4238|1234',
    amount: '2951',
    type: TxType.transfer,
  ),
);

/// In-memory stand-in for the suggester and the actions: answering removes a
/// suggestion, undo puts it back.
class FakePairingStore implements PairingSuggester, PairingActions {
  FakePairingStore(List<PairingSuggestion> initial) : items = [...initial];

  final List<PairingSuggestion> items;
  final List<String> accepted = [];
  final List<String> rejected = [];

  @override
  Future<List<PairingSuggestion>> suggest({required int nowMs}) async => [
    ...items,
  ];

  @override
  Future<PairingDecision?> accept(PairingSuggestion s) async {
    items.removeWhere((i) => i.key == s.key);
    accepted.add(s.key);
    return PairingDecision(s, accepted: true);
  }

  @override
  Future<PairingDecision> reject(PairingSuggestion s) async {
    items.removeWhere((i) => i.key == s.key);
    rejected.add(s.key);
    return PairingDecision(s, accepted: false);
  }

  @override
  Future<void> undo(PairingDecision d) async {
    items.insert(0, d.suggestion);
    (d.accepted ? accepted : rejected).remove(d.suggestion.key);
  }

  List<Override> get overrides => [
    pairingSuggesterProvider.overrideWithValue(this),
    pairingActionsProvider.overrideWithValue(this),
  ];
}
