/// A curated list of known banks so non-technical users just pick their bank
/// (instead of typing sender names). Each entry carries the matcher strings used
/// to recognize the bank's SMS sender: a bank matches when ANY matcher appears
/// as a (case-insensitive) substring of the incoming sender.
///
/// Matchers are stored lowercase. To support more banks, add entries here.
class BankCatalogEntry {
  const BankCatalogEntry({required this.label, required this.matchers});

  /// User-facing bank name (also stored as the bank's name).
  final String label;

  /// Lowercase substrings; a sender matches if it contains any of them.
  final List<String> matchers;
}

const List<BankCatalogEntry> kBankCatalog = [
  BankCatalogEntry(
    label: 'City Bank',
    matchers: ['city bank', 'citybank', 'citytouch', 'city amex', 'city_amex'],
  ),
  BankCatalogEntry(
    label: 'MTB',
    matchers: ['mtb', '01401-195498', '01401195498'],
  ),
  BankCatalogEntry(label: 'EBL', matchers: ['ebl', 'eastern bank limited']),
  BankCatalogEntry(label: 'StanChart (SCB)', matchers: ['scb', 'stanchart']),
  BankCatalogEntry(label: 'BRAC Bank', matchers: ['brac', 'brac-bank']),
];

/// Looks up a catalog entry by its exact label, or null if unknown.
BankCatalogEntry? bankCatalogByLabel(String label) {
  for (final entry in kBankCatalog) {
    if (entry.label == label) return entry;
  }
  return null;
}

/// The single catalog entry whose matchers appear in [sender], or null when
/// zero or more than one match.
///
/// Used only by the bulk inbox import, which may run before the user has set up
/// any bank: it recognizes the sender from the built-in catalog so the account
/// can be created on the spot. Ambiguity resolves to null — the import creates
/// accounts on the user's behalf, so it must never guess which one.
BankCatalogEntry? singleCatalogMatch(String sender) {
  final lower = sender.toLowerCase();
  BankCatalogEntry? found;
  for (final entry in kBankCatalog) {
    // Catalog matchers are stored lowercase, so only the sender needs folding.
    if (entry.matchers.any(lower.contains)) {
      if (found != null) return null;
      found = entry;
    }
  }
  return found;
}

/// Serializes a bank's matchers for the `matchers` column (newline-joined, since
/// a matcher may contain spaces).
String matchersToColumn(List<String> matchers) => matchers.join('\n');

/// Parses the stored `matchers` column back into a list.
List<String> matchersFromColumn(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  return stored.split('\n').where((m) => m.isNotEmpty).toList();
}
