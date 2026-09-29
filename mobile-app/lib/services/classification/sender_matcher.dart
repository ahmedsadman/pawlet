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

final _fourDigits = RegExp(r'^\d{4}$');

/// The two halves of a `"first4|last4"` [cardDigits] value, or null when it is
/// absent or malformed.
///
/// Both halves must be exactly four digits. `banks_page.dart` enforces that on
/// input, but backup-restored and legacy rows reach this parser unchecked, and
/// [contentLooselyMatchesCardDigits] would treat a shorter half as a wildcard.
({String first4, String last4})? _parseCardDigits(String? cardDigits) {
  if (cardDigits == null) return null;
  final parts = cardDigits.split('|');
  if (parts.length != 2) return null;
  if (!_fourDigits.hasMatch(parts[0]) || !_fourDigits.hasMatch(parts[1])) {
    return null;
  }
  return (first4: parts[0], last4: parts[1]);
}

/// True when [content] contains a card number matching a `"first4|last4"`
/// [cardDigits] pattern, allowing masking/spacing between the two groups
/// (e.g. "4238****3241", "4238 12 3241").
bool contentMatchesCardDigits(String content, String? cardDigits) {
  final digits = _parseCardDigits(cardDigits);
  if (digits == null) return false;
  // The {0,16} gap mirrors the card regex in spec/03 (and Phase 5's writer):
  // enough to span masked/spaced middles like "4238****3241" or "4238 12 3241".
  final pattern = RegExp(
    '${RegExp.escape(digits.first4)}'
    '[\\dXx*\\s\\-]{0,16}'
    '${RegExp.escape(digits.last4)}',
    caseSensitive: false,
  );
  return pattern.hasMatch(content);
}

final _digitRun = RegExp(r'\d+');
final _maskChar = RegExp(r'[Xx*]');
final _gapChars = RegExp(r'^[\dXx*\s\-]*$');

/// Longest gap between a masked card's two visible groups, mirroring the window
/// the strict matcher allows.
const _maxGap = 16;

bool _isPrefixEitherWay(String a, String b) =>
    a.startsWith(b) || b.startsWith(a);

/// True when [content] shows a masked card whose visible digits are consistent
/// with [cardDigits], for banks that expose fewer than four digits per side
/// (e.g. "000***111" against a stored "0009|4111").
///
/// Looser than [contentMatchesCardDigits] and therefore only a fallback: the
/// gap must hold a mask character, so amounts and reference numbers cannot read
/// as cards, and the visible groups must be a genuine prefix/suffix of the
/// stored ones, so a card differing at the fourth digit is still rejected.
///
/// Pairs whole digit runs rather than matching one card-shaped pattern. A single
/// pattern would let an unrelated number next to the card claim the match and
/// consume it — "Trx 500 000***111" pairs 500 with 000, fails the mask check,
/// and the real card is never reconsidered. Runs are maximal by construction, so
/// a head is never read out of the middle of a longer number.
bool contentLooselyMatchesCardDigits(String content, String? cardDigits) {
  final digits = _parseCardDigits(cardDigits);
  if (digits == null) return false;
  final runs = _digitRun.allMatches(content).toList();
  for (var i = 0; i < runs.length; i++) {
    final head = runs[i][0]!;
    if (head.length < 3 || head.length > 6) continue;
    if (!_isPrefixEitherWay(digits.first4, head)) continue;
    for (var j = i + 1; j < runs.length; j++) {
      final gap = content.substring(runs[i].end, runs[j].start);
      // Gaps only widen as j advances, so an over-long or invalid one ends
      // this head's candidates rather than just skipping the pair.
      if (gap.length > _maxGap || !_gapChars.hasMatch(gap)) break;
      if (!_maskChar.hasMatch(gap)) continue;
      final tail = runs[j][0]!;
      if (tail.length < 3 || tail.length > 4) continue;
      if (digits.last4.endsWith(tail)) return true;
    }
  }
  return false;
}

/// The single bank whose matchers match [sender], or null when zero or more
/// than one match. Ambiguity (e.g. two accounts sharing matchers) resolves to
/// null so the caller leaves the row unlinked rather than guessing.
Bank? singleSenderMatch(String sender, List<Bank> banks) {
  Bank? found;
  for (final bank in banks) {
    if (senderMatchesBank(sender, bank)) {
      if (found != null) return null;
      found = bank;
    }
  }
  return found;
}

/// The first credit bank whose full card digits appear in [content], or null.
///
/// Callers that weigh the card against another signal use this rather than
/// [matchCreditCardInContent]: eight matching digits are strong evidence, three
/// per side are not, so only the exact form should outrank a sender match.
Bank? matchExactCreditCardInContent(String content, List<Bank> banks) {
  for (final bank in banks) {
    if (bank.isCredit && contentMatchesCardDigits(content, bank.cardDigits)) {
      return bank;
    }
  }
  return null;
}

/// The credit bank whose card digits appear in [content], or null.
/// Reused by the finance writer (Phase 5) to attach a bill/transaction to a card.
///
/// An exact match anywhere in the list wins outright. Only when no card matches
/// exactly does the loose fallback run, and it must land on exactly one card —
/// three visible digits leave the trailing group as the sole discriminator, so
/// an ambiguous result is left unattributed rather than guessed.
///
/// The two passes are deliberately asymmetric: the exact pass keeps its original
/// first-hit-wins behaviour, since four digits per side already make a collision
/// implausible and changing it would alter how existing cards resolve.
Bank? matchCreditCardInContent(String content, List<Bank> banks) =>
    matchExactCreditCardInContent(content, banks) ??
    matchLooseCreditCardInContent(content, banks);

/// The one credit bank whose partially-masked card digits fit [content], or
/// null when none or more than one fits.
///
/// Three visible digits leave the trailing group as the sole discriminator, so
/// an ambiguous result is left unattributed rather than guessed.
Bank? matchLooseCreditCardInContent(String content, List<Bank> banks) {
  Bank? found;
  for (final bank in banks) {
    if (bank.isCredit &&
        contentLooselyMatchesCardDigits(content, bank.cardDigits)) {
      if (found != null) return null;
      found = bank;
    }
  }
  return found;
}

/// The account a transaction SMS belongs to, or null when nothing fits.
///
/// Bank identity is deterministic (no model guesses it): a full card-digit
/// match in the content wins, then the single bank whose matchers match the
/// sender, then a partially-masked card. The sender outranks the masked card
/// because a deposit SMS printing a masked account number can resemble one,
/// and landing on a card would silently stop the deposit's balance from
/// updating. Ambiguous resolves to null, leaving the row unlinked.
///
/// Shared so the writer and the bulk import's orphan relink cannot drift apart
/// — a relink that resolved differently would move rows between accounts.
Bank? resolveTransactionBank(String sender, String content, List<Bank> banks) =>
    matchExactCreditCardInContent(content, banks) ??
    singleSenderMatch(sender, banks) ??
    matchLooseCreditCardInContent(content, banks);

/// Layer-1 gate: the banks an SMS plausibly belongs to — sender-token match, or
/// (for credit cards) card digits found in the content. An empty result means
/// the SMS is ignored with no LLM call.
///
/// Deliberately more permissive than [matchCreditCardInContent]: a loose card
/// match gates the SMS in without any ambiguity check, because a false positive
/// here costs one LLM call while a false negative discards a real bill unseen.
List<Bank> gateBanks(String sender, String content, List<Bank> banks) {
  return banks.where((b) => _gateMatches(sender, content, b)).toList();
}

/// Whether the SMS belongs to *any* of [banks] — [gateBanks]'s rule without
/// materializing the matches. The bulk inbox import asks this once per message
/// across a whole inbox and only needs the yes/no, so the per-message list
/// allocation is pure waste there.
bool hasGateBank(String sender, String content, List<Bank> banks) =>
    banks.any((b) => _gateMatches(sender, content, b));

bool _gateMatches(String sender, String content, Bank bank) =>
    senderMatchesBank(sender, bank) ||
    (bank.isCredit &&
        (contentMatchesCardDigits(content, bank.cardDigits) ||
            contentLooselyMatchesCardDigits(content, bank.cardDigits)));
