import 'package:decimal/decimal.dart';

import 'llm_provider.dart';

/// Maps the fused classify+extract JSON object to a [ClassifyResult].
///
/// Shared by [OpenRouterProvider] (the model's own output) and
/// [PawletProxyProvider] (the server's normalised copy of it), so both paths
/// enforce exactly the same rules. `category` is authoritative: the matching
/// block is read and the other is ignored. Absent/null means neither; any
/// other value is malformed and surfaces as a retryable [LlmException].
ClassifyResult parseClassifyObject(Map<String, dynamic> obj) {
  final category = obj['category'];
  if (category == 'transaction') {
    return ClassifyResult(
      category: SmsCategory.transaction,
      transaction: _metadata(obj['transaction']),
    );
  }
  if (category == 'bill') {
    return ClassifyResult(category: SmsCategory.bill, bill: _bill(obj['bill']));
  }
  if (category == null) return const ClassifyResult.none();
  throw LlmException('unexpected category: $category', retryable: true);
}

/// Parses a `Retry-After` header. Only the delta-seconds form is honored: a
/// non-negative integer becomes that many seconds. Missing / non-integer /
/// negative / HTTP-date forms return null (an HTTP-date would need a clock,
/// which the providers deliberately avoid).
Duration? parseRetryAfter(String? value) {
  if (value == null) return null;
  final n = int.tryParse(value.trim());
  if (n == null || n < 0) return null;
  return Duration(seconds: n);
}

/// Parses an `X-RateLimit-Reset` header to epoch **milliseconds**. OpenRouter
/// sends an absolute epoch-ms timestamp (13-digit; confirmed via captured 429
/// responses), so the raw integer is carried as-is — no unit conversion. A
/// stray seconds value would land in 1970, becoming a past timestamp that
/// ProcessingService floors to backoff; its 24h clamp bounds any bad value.
/// Missing / non-integer / negative returns null.
int? parseResetAt(String? value) {
  if (value == null) return null;
  final n = int.tryParse(value.trim());
  if (n == null || n < 0) return null;
  return n;
}

MetadataResult _metadata(Object? raw) {
  if (raw is! Map) return const MetadataResult();
  final balance = _numStr(raw['balance']);

  var amount = _numStr(raw['amount']);
  var originalAmount = _numStr(raw['original_amount']);
  var type = _txType(raw['transaction_type']);
  // amount / original_amount / transaction_type are all-or-nothing.
  if (amount == null || originalAmount == null || type == null) {
    amount = null;
    originalAmount = null;
    type = null;
  }

  // original_currency is only meaningful alongside a number (amount/balance).
  var currency = _currency(raw['original_currency']);
  if (amount == null && balance == null) currency = null;

  return MetadataResult(
    balance: balance,
    amount: amount,
    originalAmount: originalAmount,
    transactionType: type,
    originalCurrency: currency,
  );
}

BillMetadataResult _bill(Object? raw) {
  if (raw is! Map) return const BillMetadataResult();

  // normalized_total_due / original_amount / original_currency are
  // all-or-nothing; the statement period components stay independent.
  var total = _numStr(raw['normalized_total_due']);
  var originalAmount = _numStr(raw['original_amount']);
  var currency = _currency(raw['original_currency']);
  if (total == null || originalAmount == null || currency == null) {
    total = null;
    originalAmount = null;
    currency = null;
  }

  return BillMetadataResult(
    normalizedTotalDue: total,
    originalAmount: originalAmount,
    originalCurrency: currency,
    statementMonth: _month(raw['statement_month']),
    statementYear: _year(raw['statement_year']),
  );
}

/// Returns a decimal-as-string when [value] parses as a number, else null.
String? _numStr(Object? value) {
  if (value == null) return null;
  final s = value.toString();
  return Decimal.tryParse(s) == null ? null : s;
}

String? _currency(Object? value) {
  if (value is! String) return null;
  return RegExp(r'^[A-Za-z]{3}$').hasMatch(value) ? value.toUpperCase() : null;
}

String? _txType(Object? value) {
  if (value is! String) return null;
  return const {'income', 'expense', 'transfer'}.contains(value) ? value : null;
}

int? _month(Object? value) {
  final n = value is num ? value.toInt() : int.tryParse('$value');
  return (n != null && n >= 1 && n <= 12) ? n : null;
}

int? _year(Object? value) {
  final n = value is num ? value.toInt() : int.tryParse('$value');
  return (n != null && n >= 2000 && n <= 2100) ? n : null;
}
