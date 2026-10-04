import 'package:decimal/decimal.dart';

import '../../models/sms_record.dart';
import '../llm/llm_provider.dart';
import 'local_classifier.dart';
import 'local_gate.dart';

/// The result of running an SMS through the pipeline: the decided category and
/// the extracted metadata.
class ClassificationOutcome {
  const ClassificationOutcome({
    required this.category,
    this.transaction,
    this.bill,
    required this.parseSource,
  });

  final SmsCategory category;
  final MetadataResult? transaction;
  final BillMetadataResult? bill;

  /// Which engine produced this outcome: on-device ([ParseSource.local]) or
  /// cloud LLM ([ParseSource.llm]).
  final ParseSource parseSource;
}

/// Orchestrates the classification pipeline: on-device model ([classifyLocal])
/// and, when one is configured, the cloud LLM ([classifyRemote]). The caller
/// applies the Layer-1 sender/card gate before invoking either method, and
/// checks [hasLlm] before the second.
class Classifier {
  // ignore: prefer_initializing_formals — a named param can't be private (_local).
  Classifier(this._llm, {LocalClassifier? local}) : _local = local;

  final LlmProvider? _llm;
  final LocalClassifier? _local;

  /// Whether a cloud fallback exists. False in no-LLM mode, where the caller
  /// must treat an on-device rejection as terminal rather than deferring a
  /// message that nothing will ever come back for.
  bool get hasLlm => _llm != null;

  /// The on-device pass. A null `outcome` means the caller must either run
  /// [classifyRemote] or, if it cannot reach the network, defer the message.
  ///
  /// `declined` separates the two ways that can happen: true only when the
  /// model ran on this content and [decideLocal] turned the prediction down,
  /// false when no prediction existed at all (no model wired, or the model
  /// failed to load or crashed). The caller needs the distinction because it
  /// persists the verdict in a flag it never clears: a message deferred while
  /// the model was broken would otherwise be routed to the paid LLM forever,
  /// with no way back on-device even though nothing ever judged it.
  ///
  /// Makes no network call under any circumstance, so it is safe to run while
  /// offline. Deliberately does NOT apply the Layer-1 gate: a gate miss is a
  /// terminal queue state rather than a classification, and only the caller can
  /// tell it apart from "needs the LLM".
  Future<({ClassificationOutcome? outcome, bool declined})> classifyLocal({
    required String content,
    required String currency,
    Decimal? usdRate,
  }) async {
    final decision = await runLocalModel(
      content,
      local: _local,
      currency: currency,
      usdRate: usdRate,
      // Derived rather than injected: with no provider there is nothing to
      // defer to, so the thresholds would only throw away the one answer this
      // install can produce.
      acceptance: hasLlm ? GateAcceptance.gated : GateAcceptance.ungated,
    );

    if (!decision.accepted) {
      return (outcome: null, declined: decision.declined);
    }

    final r = decision.result!;
    return (
      outcome: ClassificationOutcome(
        category: r.category,
        transaction: r.transaction,
        bill: r.bill,
        parseSource: ParseSource.local,
      ),
      declined: false,
    );
  }

  /// The single fused classify+extract LLM call. Throws [LlmException] straight
  /// through so the caller can apply its retry/backoff policy.
  Future<ClassificationOutcome> classifyRemote({
    required String sender,
    required String content,
    required String currency,
  }) async {
    final llm = _llm;
    // A programming error, not a runtime path: ProcessingService checks
    // [hasLlm] first. Mirrors the bulk importer, which takes a LocalClassifier
    // precisely so no path to the network is reachable from it.
    if (llm == null) {
      throw StateError('classifyRemote called with no LLM provider');
    }

    final result = await llm.classifyAndExtract(
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
}
