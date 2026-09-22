import '../../models/finance/bank.dart';

/// Layer 1 of the pipeline: decide whether an incoming SMS belongs to any of the
/// user's banks (by sender name or credit-card digits) before spending an LLM
/// call. See spec/03-classification-pipeline.md.

/// True when any of [bank]'s catalog matchers appears as a case-insensitive
/// substring of the incoming [sender].
bool senderMatchesBank(String sender, Bank bank) {
  final lower = sender.toLowerCase();
  return bank.matchers.any((m) => lower.contains(m.toLowerCase()));
}

/// True when [content] contains a card number matching a `"first4|last4"`
/// [cardDigits] pattern, allowing masking/spacing between the two groups
/// (e.g. "4238****3241", "4238 12 3241").
bool contentMatchesCardDigits(String content, String? cardDigits) {
  if (cardDigits == null) return false;
  final parts = cardDigits.split('|');
  if (parts.length != 2) return false;
  final first4 = parts[0];
  final last4 = parts[1];
  if (first4.isEmpty || last4.isEmpty) return false;
  // The {0,16} gap mirrors the card regex in spec/03 (and Phase 5's writer):
  // enough to span masked/spaced middles like "4238****3241" or "4238 12 3241".
  final pattern = RegExp(
    '${RegExp.escape(first4)}[\\dXx*\\s\\-]{0,16}${RegExp.escape(last4)}',
    caseSensitive: false,
  );
  return pattern.hasMatch(content);
}

/// The first credit bank whose card digits appear in [content], or null.
/// Reused by the finance writer (Phase 5) to attach a bill/transaction to a card.
Bank? matchCreditCardInContent(String content, List<Bank> banks) {
  for (final bank in banks) {
    if (bank.isCredit && contentMatchesCardDigits(content, bank.cardDigits)) {
      return bank;
    }
  }
  return null;
}

/// Layer-1 gate: the banks an SMS plausibly belongs to — sender-token match, or
/// (for credit cards) card digits found in the content. An empty result means
/// the SMS is ignored with no LLM call.
List<Bank> gateBanks(String sender, String content, List<Bank> banks) {
  return banks
      .where(
        (b) =>
            senderMatchesBank(sender, b) ||
            (b.isCredit && contentMatchesCardDigits(content, b.cardDigits)),
      )
      .toList();
}
