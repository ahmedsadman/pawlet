/// Sender/bank-name tokenization used to gate an SMS by its sender before it is
/// categorized. A bank's match tokens are computed once (on create/update) from
/// its main name plus its alternate sender names; at classification time the
/// incoming sender is tokenized the same way and any single overlapping token
/// passes the gate.
library;

/// Lowercases [input] and splits it into a set of alphanumeric word tokens.
/// Empty tokens and separators (spaces, dashes, punctuation) are dropped.
Set<String> tokenize(String input) {
  return input
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((t) => t.isNotEmpty)
      .toSet();
}

/// Precomputes a bank's match-token set from its main [name] and its
/// [alternateNames] (free text: comma / newline / space separated). Sorted so
/// the stored form is stable. Run once on create/update — never per SMS.
List<String> buildMatchTokens(String name, String alternateNames) {
  final tokens = <String>{...tokenize(name), ...tokenize(alternateNames)};
  final sorted = tokens.toList()..sort();
  return sorted;
}

/// Splits the stored space-joined `match_tokens` column into a token list.
List<String> matchTokensFromColumn(String? stored) {
  if (stored == null || stored.isEmpty) return const [];
  return stored.split(' ');
}

/// True when any word token of [sender] matches one of the bank's precomputed
/// [tokens]. Case- and punctuation-insensitive.
bool senderMatchesTokens(String sender, Iterable<String> tokens) {
  if (tokens.isEmpty) return false;
  final set = tokens is Set<String> ? tokens : tokens.toSet();
  for (final t in tokenize(sender)) {
    if (set.contains(t)) return true;
  }
  return false;
}
