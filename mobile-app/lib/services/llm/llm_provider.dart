/// The category the classifier assigned to an SMS. `none` means neither a
/// transaction nor a bill (the message is ignored).
enum SmsCategory { transaction, bill, none }

/// Transaction metadata extracted from an SMS. Monetary values are strings
/// (decimal-as-string, matching the finance models) already converted to the
/// user's normalized currency. All fields are nullable — the LLM sets them
/// together per the prompt's pairing rules.
class MetadataResult {
  const MetadataResult({
    this.balance,
    this.amount,
    this.transactionType,
    this.originalCurrency,
    this.originalAmount,
  });

  final String? balance;
  final String? amount;

  /// `income` | `expense` | `transfer` or null.
  final String? transactionType;
  final String? originalCurrency;
  final String? originalAmount;
}

/// Credit-card bill metadata extracted from an SMS. `normalizedTotalDue` is in
/// the user's normalized currency; the statement period components may be null.
class BillMetadataResult {
  const BillMetadataResult({
    this.normalizedTotalDue,
    this.originalAmount,
    this.originalCurrency,
    this.statementMonth,
    this.statementYear,
  });

  final String? normalizedTotalDue;
  final String? originalAmount;
  final String? originalCurrency;
  final int? statementMonth;
  final int? statementYear;
}

/// The result of the single fused classify+extract call. Exactly one of
/// [transaction]/[bill] is non-null when [category] is transaction/bill; both
/// are null when [category] is none.
class ClassifyResult {
  const ClassifyResult({required this.category, this.transaction, this.bill});

  const ClassifyResult.none()
    : category = SmsCategory.none,
      transaction = null,
      bill = null;

  final SmsCategory category;
  final MetadataResult? transaction;
  final BillMetadataResult? bill;
}

/// Failure from an LLM call. [retryable] distinguishes transient failures
/// (rate limits, 5xx, network, timeout, malformed output) that the processing
/// queue should back off and retry, from fatal ones (bad API key, bad request)
/// that should fail the message immediately.
class LlmException implements Exception {
  const LlmException(
    this.message, {
    required this.retryable,
    this.retryAfter,
    this.resetAtEpochMs,
    this.needsForeground = false,
  });

  final String message;
  final bool retryable;

  /// The call cannot be made from this isolate at all — the proxy needs a
  /// session only the foreground app can mint. Not an attempt: the queue
  /// releases the row untouched for the foreground instead of retrying it.
  final bool needsForeground;

  /// From a `Retry-After` header: a relative "don't retry before" delay. Null
  /// when absent or unparseable. Both hints are floors combined with our
  /// backoff (max), never a replacement — see ProcessingService.
  final Duration? retryAfter;

  /// From an `X-RateLimit-Reset` header: an absolute reset time as epoch
  /// **milliseconds** (normalized from seconds when needed). Null when absent
  /// or unparseable.
  final int? resetAtEpochMs;

  @override
  String toString() =>
      'LlmException($message, retryable=$retryable, '
      'retryAfter=$retryAfter, resetAtEpochMs=$resetAtEpochMs, '
      'needsForeground=$needsForeground)';
}

/// Provider-agnostic SMS classifier + extractor. Implementations perform one
/// call that both classifies the message and extracts the matching metadata,
/// so the interface can be swapped (OpenRouter today, anything later).
abstract class LlmProvider {
  Future<ClassifyResult> classifyAndExtract({
    required String content,
    required String sender,
    required String currency,
  });
}
