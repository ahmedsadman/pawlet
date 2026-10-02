import 'package:decimal/decimal.dart';

/// Strips grouping commas, currency symbols/letters, and any other non-numeric
/// characters from a model-extracted amount, keeping digits and a single
/// decimal point. Returns a decimal-as-string (matching the finance models), or
/// null when nothing parseable remains. The decimal point is never dropped.
///
/// Examples: "85,000" -> "85000", "85,000Tk." -> "85000",
/// "BDT 4,924.35" -> "4924.35".
String? parseLocalAmount(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
  if (cleaned.isEmpty) return null;
  // Keep the first decimal point and concatenate any later fractional digits.
  // This is intentionally lossy for a malformed multi-dot span (e.g. "1.234.56"
  // -> "1.23456"): such a span is almost certainly a mis-extraction, but it is
  // already guarded by the NERc gate, so we coerce rather than add a branch.
  final firstDot = cleaned.indexOf('.');
  var normalized = firstDot == -1
      ? cleaned
      : cleaned.substring(0, firstDot + 1) +
            cleaned.substring(firstDot + 1).replaceAll('.', '');
  // Drop a trailing point left by an abbreviation ("85,000Tk." -> "85000.").
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  // Normalise a leading point (".35" -> "0.35") so it parses as a decimal.
  if (normalized.startsWith('.')) normalized = '0$normalized';
  if (normalized.isEmpty || Decimal.tryParse(normalized) == null) return null;
  return normalized;
}

/// A parsed bill statement period.
class StatementPeriod {
  const StatementPeriod(this.month, this.year);
  final int month; // 1..12
  final int year; // 4-digit
}

const Map<String, int> _months = {
  'jan': 1,
  'january': 1,
  'feb': 2,
  'february': 2,
  'mar': 3,
  'march': 3,
  'apr': 4,
  'april': 4,
  'may': 5,
  'jun': 6,
  'june': 6,
  'jul': 7,
  'july': 7,
  'aug': 8,
  'august': 8,
  'sep': 9,
  'sept': 9,
  'september': 9,
  'oct': 10,
  'october': 10,
  'nov': 11,
  'november': 11,
  'dec': 12,
  'december': 12,
};

/// Parses a bill statement-period span into (month, year). Handles the real
/// dataset formats "AUG 2026" / "AUG2026" (3-letter month + optional space +
/// 4-digit year), the apostrophe form "Sep'26", plus full month names and
/// common numeric forms (07-2026, 10/2026, 2026-09, 04.2026). Returns null when
/// a month+year cannot be resolved.
StatementPeriod? parseStatementPeriod(String raw) {
  final s = raw.trim().toLowerCase();

  // Alphabetic month + apostrophe + 2-digit year ("sep'26"). The apostrophe is
  // required: a bare "sep 26" is far more likely a day than a year.
  final apos = RegExp(r"^([a-z]{3,9})\s*['’]\s*(\d{2})$").firstMatch(s);
  if (apos != null) {
    final name = apos.group(1)!;
    final month =
        _months[name] ??
        (name.length >= 3 ? _months[name.substring(0, 3)] : null);
    if (month != null) {
      return StatementPeriod(month, 2000 + int.parse(apos.group(2)!));
    }
  }

  // Alphabetic month + 4-digit year, either order ("aug2026", "2026 jan").
  final alpha = RegExp(
    r'([a-z]{3,9})\s*(\d{4})|(\d{4})\s*([a-z]{3,9})',
  ).firstMatch(s);
  if (alpha != null) {
    final name = (alpha.group(1) ?? alpha.group(4))!;
    final year = int.parse(alpha.group(2) ?? alpha.group(3)!);
    final month =
        _months[name] ??
        (name.length >= 3 ? _months[name.substring(0, 3)] : null);
    if (month != null) return StatementPeriod(month, year);
  }

  // MM<sep>YYYY
  final mmYYYY = RegExp(r'^(\d{1,2})[\-/.](\d{4})$').firstMatch(s);
  if (mmYYYY != null) {
    final m = int.parse(mmYYYY.group(1)!);
    final y = int.parse(mmYYYY.group(2)!);
    if (m >= 1 && m <= 12) return StatementPeriod(m, y);
  }

  // YYYY<sep>MM
  final yyyyMM = RegExp(r'^(\d{4})[\-/.](\d{1,2})$').firstMatch(s);
  if (yyyyMM != null) {
    final y = int.parse(yyyyMM.group(1)!);
    final m = int.parse(yyyyMM.group(2)!);
    if (m >= 1 && m <= 12) return StatementPeriod(m, y);
  }

  return null;
}

/// Maps a currency token found in an SMS to an ISO 4217 code (best-effort).
/// Covers the currencies the app realistically sees plus the common symbols;
/// returns null for an unrecognised token. Kept in sync with [_currencyToken].
///
/// Residual gap: an exotic currency whose token isn't listed here goes
/// undetected, so such an SMS could be accepted on-device in the wrong currency.
/// The set below covers the common cases; broaden it (or add server-side FX) as
/// more currencies appear. Documented in message-pipeline.md.
String? currencyToIso(String token) {
  final t = token.toUpperCase().replaceAll('.', '');
  switch (t) {
    case 'BDT':
    case 'TK':
    case 'TAKA':
    case '৳':
      return 'BDT';
    case 'USD':
    case r'US$':
    case r'$':
      return 'USD';
    case 'EUR':
    case '€':
      return 'EUR';
    case 'GBP':
    case '£':
      return 'GBP';
    case 'INR':
    case '₹':
      return 'INR';
    case 'JPY':
    case '¥':
      return 'JPY';
    case 'AUD':
      return 'AUD';
    case 'CAD':
      return 'CAD';
    case 'SAR':
      return 'SAR';
    case 'AED':
      return 'AED';
  }
  return null;
}

final RegExp _currencyToken = RegExp(
  r'US\$|BDT|USD|TAKA|TK\.?|EUR|GBP|INR|JPY|AUD|CAD|SAR|AED|৳|€|£|₹|¥|\$',
  caseSensitive: false,
);

/// Detects a currency ISO from the text window around the amount span
/// [start,end], mirroring predict.py's sniff_currency (nearest currency token).
/// Returns null when no recognised currency token is near the amount.
///
/// NOTE: offsets are character indices into [content]; for the ASCII bank SMS
/// this heuristic targets, substring windows are exact. Non-Latin scripts may
/// misalign slightly — acceptable for a fall-back trigger (a miss just routes to
/// the LLM). Documented as a future improvement in message-pipeline.md.
String? sniffCurrencyIso(String content, int start, int end) {
  final lo = (start - 8).clamp(0, content.length);
  final hi = (end + 8).clamp(0, content.length);
  final m = _currencyToken.firstMatch(content.substring(lo, hi));
  return m == null ? null : currencyToIso(m.group(0)!);
}
