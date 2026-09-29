import '../../data/bank_catalog.dart';
import '../../models/finance/bank.dart';
import '../classification/sender_matcher.dart';

/// Why an inbox message was let through the bulk-import gate.
///
/// [catalogEntry] is non-null only when nothing the user has set up matched and
/// the sender was recognized from the built-in catalog — the signal that a
/// deposit account may need creating before a record can be linked to it.
class BulkGateMatch {
  const BulkGateMatch({this.catalogEntry});

  final BankCatalogEntry? catalogEntry;
}

/// Layer 1 for the bulk inbox import. Wider than the live pipeline's
/// [gateBanks] because the import typically runs on a fresh install where the
/// user has no banks at all, and [gateBanks] would then reject every message: a
/// sender recognized by the built-in catalog passes too, so its messages can
/// seed the account.
///
/// Returns null when the message belongs to nothing we know about — the caller
/// drops it without writing anything, which is what keeps a 20k-message inbox
/// cheap to walk.
BulkGateMatch? bulkGate(String sender, String content, List<Bank> banks) {
  // A bank the user actually set up always wins: reporting a catalog entry here
  // would invite a duplicate account for a bank they may have renamed.
  if (hasGateBank(sender, content, banks)) return const BulkGateMatch();
  final entry = singleCatalogMatch(sender);
  return entry == null ? null : BulkGateMatch(catalogEntry: entry);
}
