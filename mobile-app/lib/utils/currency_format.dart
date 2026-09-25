// Currency and number formatting helpers (hand-rolled, no `intl` dependency).

const String _placeholder = '—';

/// Fixed mask shown in place of a numeric value when balances are hidden.
const String maskedValue = '****';

/// The masked form keeps the currency but replaces the amount: `**** BDT`.
String maskAmount(String currency) => '$maskedValue $currency';

/// Groups the integer part of a number with commas: `1234567` -> `1,234,567`.
String _group(String integerPart) {
  final buffer = StringBuffer();
  for (var i = 0; i < integerPart.length; i++) {
    if (i > 0 && (integerPart.length - i) % 3 == 0) buffer.write(',');
    buffer.write(integerPart[i]);
  }
  return buffer.toString();
}

/// Formats a number with thousands separators and two decimals: `-1,234.50`.
String formatNumber(double value) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(2);
  final dot = fixed.indexOf('.');
  final grouped = '${_group(fixed.substring(0, dot))}${fixed.substring(dot)}';
  return negative ? '-$grouped' : grouped;
}

/// Formats a decimal-string amount with its currency: `1,234.56 BDT`.
/// Returns `—` when [raw] is null or not parseable, or the mask (`**** BDT`)
/// when [hidden].
String formatAmount(String? raw, String currency, {bool hidden = false}) {
  if (hidden) return maskAmount(currency);
  final value = double.tryParse(raw ?? '');
  if (value == null) return _placeholder;
  return '${formatNumber(value)} $currency';
}

/// Formats a numeric value with its currency: `1,234.56 BDT`, or the mask
/// (`**** BDT`) when [hidden].
String formatMoney(num value, String currency, {bool hidden = false}) => hidden
    ? maskAmount(currency)
    : '${formatNumber(value.toDouble())} $currency';

/// Compact axis label: `1.2K`, `3.4M`, `2B`. Trims a trailing `.0`.
String formatCompact(num value) {
  final abs = value.abs();
  if (abs >= 1e9) return '${_trim(value / 1e9)}B';
  if (abs >= 1e6) return '${_trim(value / 1e6)}M';
  if (abs >= 1e3) return '${_trim(value / 1e3)}K';
  return _trim(value);
}

String _trim(num value) {
  final s = value.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
