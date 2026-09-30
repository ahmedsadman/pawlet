import 'package:decimal/decimal.dart';

import '../llm/llm_provider.dart';
import 'local_classifier.dart';
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

/// Runs the on-device half of the pipeline end to end: inference, then
/// [decideLocal]. A rejection means "this can only be answered by the LLM".
///
/// Shared by the live queue and the bulk inbox import. It takes a
/// [LocalClassifier] rather than the full pipeline deliberately: the import
/// must have no reachable path to the LLM, which a dependency on `Classifier`
/// would hand it.
///
/// A null [local] (no model wired) and a null prediction (asset load or runtime
/// failure — implementations never throw) are both rejections.
Future<LocalGateResult> runLocalModel(
  LocalClassifier? local,
  String content, {
  required String currency,
  Decimal? usdRate,
}) async {
  if (local == null) return const LocalGateResult.reject();
  final prediction = await local.infer(content);
  if (prediction == null) return const LocalGateResult.reject();
  return decideLocal(
    prediction,
    currency: currency,
    content: content,
    usdToBdtRate: usdRate,
  );
}

/// Decides whether the on-device prediction clears the gate and, if so, builds
/// the [ClassifyResult] that the pipeline persists — identical in shape to the
/// LLM's output, so FinanceWriter is unchanged.
///
/// Reject == "fall back to the LLM". In summary: reject when classConf < X, or
/// (for transaction/bill) NERc < X, or a required span is missing/unparseable,
/// or the detected source currency cannot be represented in [currency] — i.e.
/// anything other than the base currency itself or USD-with-a-live-[usdToBdtRate]
/// (a USD amount is converted on-device; every other foreign currency still
/// defers to the LLM).
LocalGateResult decideLocal(
  LocalPrediction pred, {
  required String currency,
  required String content,
  Decimal? usdToBdtRate,
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
    return _buildBill(
      best,
      currency: currency,
      content: content,
      usdToBdtRate: usdToBdtRate,
    );
  }
  return _buildTransaction(
    best,
    type: pred.classLabel,
    currency: currency,
    content: content,
    usdToBdtRate: usdToBdtRate,
  );
}

LocalGateResult _buildBill(
  Map<String, LocalSpan> best, {
  required String currency,
  required String content,
  Decimal? usdToBdtRate,
}) {
  final due = best['DUE'];
  if (due == null) return const LocalGateResult.reject();
  final conv = _convert(content, due, currency, usdToBdtRate);
  if (conv == null) return const LocalGateResult.reject();

  final periodSpan = best['PERIOD'];
  var period = periodSpan == null
      ? null
      : parseStatementPeriod(periodSpan.text);
  // Drop the whole period (not just the year) on an out-of-range year, so we
  // never persist a half-period with a month but no year.
  if (period != null && (period.year < 2000 || period.year > 2100)) {
    period = null;
  }
  return LocalGateResult.accept(
    ClassifyResult(
      category: SmsCategory.bill,
      bill: BillMetadataResult(
        normalizedTotalDue: conv.normalized,
        originalAmount: conv.originalAmount,
        originalCurrency: conv.originalCurrency,
        statementMonth: period?.month,
        statementYear: period?.year,
      ),
    ),
  );
}

LocalGateResult _buildTransaction(
  Map<String, LocalSpan> best, {
  required String type,
  required String currency,
  required String content,
  Decimal? usdToBdtRate,
}) {
  final amountSpan = best['AMOUNT'];
  if (amountSpan == null) return const LocalGateResult.reject();
  final conv = _convert(content, amountSpan, currency, usdToBdtRate);
  if (conv == null) return const LocalGateResult.reject();

  // Balance (if any) is only used to update a deposit's stored balance, which
  // FinanceWriter skips whenever the source currency differs from the base — so
  // for a converted USD row the balance is intentionally left in source units.
  final balanceSpan = best['BALANCE'];
  final balance = balanceSpan == null
      ? null
      : parseLocalAmount(balanceSpan.text);

  return LocalGateResult.accept(
    ClassifyResult(
      category: SmsCategory.transaction,
      transaction: MetadataResult(
        amount: conv.normalized,
        balance: balance,
        transactionType: type, // expense | income | transfer
        originalAmount: conv.originalAmount,
        originalCurrency: conv.originalCurrency,
      ),
    ),
  );
}

/// The amount resolved into the base currency: [normalized] is the base-currency
/// value, [originalAmount]/[originalCurrency] preserve the source figure.
class _Converted {
  const _Converted(this.normalized, this.originalAmount, this.originalCurrency);
  final String normalized;
  final String originalAmount;
  final String originalCurrency;
}

/// Resolves the amount at [span] into the base [currency]:
/// - no currency token near the amount, or it already matches [currency]:
///   use the amount as-is.
/// - USD into a BDT base with a live [usdToBdtRate]: convert (2-dp round).
/// - any other foreign currency, or USD with no rate: return null → reject
///   (the pipeline then falls back to the LLM, which can convert).
_Converted? _convert(
  String content,
  LocalSpan span,
  String currency,
  Decimal? usdToBdtRate,
) {
  final parsed = parseLocalAmount(span.text);
  if (parsed == null) return null;

  final iso = sniffCurrencyIso(content, span.start, span.end);
  if (iso == null || iso == currency) {
    return _Converted(parsed, parsed, currency);
  }
  if (iso == 'USD' && currency == 'BDT' && usdToBdtRate != null) {
    final normalized = (Decimal.parse(parsed) * usdToBdtRate)
        .round(scale: 2)
        .toString();
    return _Converted(normalized, parsed, 'USD');
  }
  return null;
}
