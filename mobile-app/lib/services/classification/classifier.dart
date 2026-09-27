import 'package:decimal/decimal.dart';

import '../../models/finance/bank.dart';
import '../../models/sms_record.dart';
import '../llm/llm_provider.dart';
import 'local_classifier.dart';
import 'local_gate.dart';
import 'sender_matcher.dart';

/// The result of running an SMS through the pipeline: the decided category, the
/// extracted metadata, and whether an LLM call was actually made ([llmInvoked]
/// is false when Layer 1 gated the message out — used for cost/telemetry and
/// tests).
class ClassificationOutcome {
  const ClassificationOutcome({
    required this.category,
    this.transaction,
    this.bill,
    required this.llmInvoked,
    this.parseSource,
  });

  const ClassificationOutcome.ignored()
    : category = SmsCategory.none,
      transaction = null,
      bill = null,
      llmInvoked = false,
      parseSource = null;

  final SmsCategory category;
  final MetadataResult? transaction;
  final BillMetadataResult? bill;
  final bool llmInvoked;

  /// Which engine produced this outcome, or null when the Layer-1 gate rejected
  /// it before any model ran.
  final ParseSource? parseSource;
}

/// Orchestrates the pipeline: Layer-1 sender/card gate, then (only if it passes)
/// the single fused classify+extract LLM call. Throws [LlmException] straight
/// through so the processing queue can apply its retry/backoff policy.
class Classifier {
  // ignore: prefer_initializing_formals — a named param can't be private (_local).
  Classifier(this._llm, {LocalClassifier? local}) : _local = local;

  final LlmProvider _llm;
  final LocalClassifier? _local;

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

    // On-device first: skip the network entirely when the model is confident.
    final local = _local;
    if (local != null) {
      final prediction = await local.infer(content);
      if (prediction != null) {
        final decision = decideLocal(
          prediction,
          currency: currency,
          content: content,
          usdToBdtRate: usdRate,
        );
        if (decision.accepted) {
          final r = decision.result!;
          return ClassificationOutcome(
            category: r.category,
            transaction: r.transaction,
            bill: r.bill,
            llmInvoked: false,
            parseSource: ParseSource.local,
          );
        }
      }
    }

    final result = await _llm.classifyAndExtract(
      content: content,
      sender: sender,
      currency: currency,
    );

    return ClassificationOutcome(
      category: result.category,
      transaction: result.transaction,
      bill: result.bill,
      llmInvoked: true,
      parseSource: ParseSource.llm,
    );
  }
}
