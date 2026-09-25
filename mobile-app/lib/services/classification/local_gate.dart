import '../llm/llm_provider.dart';
import 'local_model.dart';
import 'local_parsers.dart';

/// Outcome of the local-model gate: either an accepted [ClassifyResult] built
/// entirely on-device, or a rejection that tells the pipeline to call the LLM.
class LocalGateResult {
  const LocalGateResult.accept(ClassifyResult this.result) : accepted = true;
  const LocalGateResult.reject() : accepted = false, result = null;

  final bool accepted;
  final ClassifyResult? result;
}

/// Decides whether the on-device prediction clears the gate and, if so, builds
/// the [ClassifyResult] that the pipeline persists — identical in shape to the
/// LLM's output, so FinanceWriter is unchanged.
///
/// Reject == "fall back to the LLM". In summary: reject when classConf < X, or
/// (for transaction/bill) NERc < X, or a required span is missing/unparseable,
/// or the detected source currency differs from [currency] (the local model
/// cannot convert FX).
LocalGateResult decideLocal(
  LocalPrediction pred, {
  required String currency,
  required String content,
}) {
  if (pred.classConfidence < kLocalConfidenceThreshold) {
    return const LocalGateResult.reject();
  }

  // Confident "null": ignore on-device and never spend an LLM call. NER is not
  // considered for null — there are no fields to extract.
  if (pred.classLabel == 'null') {
    return const LocalGateResult.accept(ClassifyResult.none());
  }

  if (pred.spans.isEmpty) return const LocalGateResult.reject();

  // NERc = weakest span confidence across EVERY emitted span (spurious
  // low-confidence duplicates included), matching the model-training semantics.
  final nerc = pred.spans
      .map((s) => s.confidence)
      .reduce((a, b) => a < b ? a : b);
  if (nerc < kLocalConfidenceThreshold) return const LocalGateResult.reject();

  // Contention: keep the highest-confidence span per entity type.
  final best = <String, LocalSpan>{};
  for (final s in pred.spans) {
    final existing = best[s.entity];
    if (existing == null || s.confidence > existing.confidence) {
      best[s.entity] = s;
    }
  }

  if (pred.classLabel == 'bill') {
    return _buildBill(best, currency: currency, content: content);
  }
  return _buildTransaction(
    best,
    type: pred.classLabel,
    currency: currency,
    content: content,
  );
}

LocalGateResult _buildBill(
  Map<String, LocalSpan> best, {
  required String currency,
  required String content,
}) {
  final due = best['DUE'];
  if (due == null) return const LocalGateResult.reject();
  if (_mismatchedCurrency(content, due, currency)) {
    return const LocalGateResult.reject();
  }
  final total = parseLocalAmount(due.text);
  if (total == null) return const LocalGateResult.reject();

  final periodSpan = best['PERIOD'];
  final period = periodSpan == null
      ? null
      : parseStatementPeriod(periodSpan.text);
  final year = period?.year;
  return LocalGateResult.accept(
    ClassifyResult(
      category: SmsCategory.bill,
      bill: BillMetadataResult(
        normalizedTotalDue: total,
        originalAmount: total, // same currency (mismatch already rejected)
        originalCurrency: currency,
        statementMonth: period?.month,
        statementYear: (year != null && year >= 2000 && year <= 2100)
            ? year
            : null,
      ),
    ),
  );
}

LocalGateResult _buildTransaction(
  Map<String, LocalSpan> best, {
  required String type,
  required String currency,
  required String content,
}) {
  final amountSpan = best['AMOUNT'];
  if (amountSpan == null) return const LocalGateResult.reject();
  if (_mismatchedCurrency(content, amountSpan, currency)) {
    return const LocalGateResult.reject();
  }
  final amount = parseLocalAmount(amountSpan.text);
  if (amount == null) return const LocalGateResult.reject();

  final balanceSpan = best['BALANCE'];
  final balance = balanceSpan == null
      ? null
      : parseLocalAmount(balanceSpan.text);

  return LocalGateResult.accept(
    ClassifyResult(
      category: SmsCategory.transaction,
      transaction: MetadataResult(
        amount: amount,
        balance: balance,
        transactionType: type, // expense | income | transfer
        originalAmount: amount, // same currency
        originalCurrency: currency,
      ),
    ),
  );
}

bool _mismatchedCurrency(String content, LocalSpan span, String currency) {
  final iso = sniffCurrencyIso(content, span.start, span.end);
  return iso != null && iso != currency;
}
