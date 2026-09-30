import 'package:decimal/decimal.dart';

import '../../models/finance/bank.dart';
import '../../models/sms_record.dart';
import '../llm/llm_provider.dart';
import 'local_classifier.dart';
import 'local_gate.dart';
import 'sender_matcher.dart';

/// The result of running an SMS through the pipeline: the decided category and
/// the extracted metadata.
class ClassificationOutcome {
  const ClassificationOutcome({
    required this.category,
    this.transaction,
    this.bill,
    this.parseSource,
  });

  const ClassificationOutcome.ignored()
    : category = SmsCategory.none,
      transaction = null,
      bill = null,
      parseSource = null;

  final SmsCategory category;
  final MetadataResult? transaction;
  final BillMetadataResult? bill;

  /// Which engine produced this outcome, or null when the Layer-1 gate rejected
  /// it before any model ran.
  final ParseSource? parseSource;
}

/// Orchestrates the classification pipeline in three parts: Layer-1 sender/card
/// gate, on-device model ([classifyLocal]), and cloud LLM ([classifyRemote]).
///
/// The new two-method path ([classifyLocal] + [classifyRemote]) requires the
/// caller to apply the gate. The retained [classify] method still runs the gate
/// internally for the processing queue until it is reworked to drive the two
/// halves itself.
class Classifier {
  // ignore: prefer_initializing_formals — a named param can't be private (_local).
  Classifier(this._llm, {LocalClassifier? local}) : _local = local;

  final LlmProvider _llm;
  final LocalClassifier? _local;

  /// The on-device pass. Returns null when the model is unavailable or not
  /// confident enough — the caller must then either run [classifyRemote] or, if
  /// it cannot reach the network, defer the message. Null deliberately does not
  /// distinguish "no model" from "not confident" — the queue only needs to know
  /// whether to spend an LLM call, and [runLocalModel] exposes the structured
  /// result if that ever changes.
  ///
  /// Makes no network call under any circumstance, so it is safe to run while
  /// offline. Deliberately does NOT apply the Layer-1 gate: a gate miss is a
  /// terminal queue state rather than a classification, and only the caller can
  /// tell it apart from "needs the LLM".
  Future<ClassificationOutcome?> classifyLocal({
    required String content,
    required String currency,
    Decimal? usdRate,
  }) async {
    final decision = await runLocalModel(
      content,
      local: _local,
      currency: currency,
      usdRate: usdRate,
    );

    if (!decision.accepted) return null;

    final r = decision.result!;
    return ClassificationOutcome(
      category: r.category,
      transaction: r.transaction,
      bill: r.bill,
      parseSource: ParseSource.local,
    );
  }

  /// The single fused classify+extract LLM call. Throws [LlmException] straight
  /// through so the caller can apply its retry/backoff policy.
  Future<ClassificationOutcome> classifyRemote({
    required String sender,
    required String content,
    required String currency,
  }) async {
    final result = await _llm.classifyAndExtract(
      content: content,
      sender: sender,
      currency: currency,
    );

    return ClassificationOutcome(
      category: result.category,
      transaction: result.transaction,
      bill: result.bill,
      parseSource: ParseSource.llm,
    );
  }

  /// Gate, then on-device, then the LLM — the whole pipeline in one call.
  ///
  /// Retained for the processing queue until it is reworked to drive the two
  /// halves itself, which is what lets it defer an LLM-bound message while
  /// offline instead of blocking on one.
  Future<ClassificationOutcome> classify({
    required String sender,
    required String content,
    required List<Bank> banks,
    required String currency,
    Decimal? usdRate,
  }) async {
    if (gateBanks(sender, content, banks).isEmpty) {
      return const ClassificationOutcome.ignored();
    }

    final localOutcome = await classifyLocal(
      content: content,
      currency: currency,
      usdRate: usdRate,
    );

    if (localOutcome != null) {
      return localOutcome;
    }

    return classifyRemote(sender: sender, content: content, currency: currency);
  }
}
