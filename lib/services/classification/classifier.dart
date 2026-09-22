import '../../models/finance/bank.dart';
import '../llm/llm_provider.dart';
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
  });

  const ClassificationOutcome.ignored()
    : category = SmsCategory.none,
      transaction = null,
      bill = null,
      llmInvoked = false;

  final SmsCategory category;
  final MetadataResult? transaction;
  final BillMetadataResult? bill;
  final bool llmInvoked;
}

/// Orchestrates the pipeline: Layer-1 sender/card gate, then (only if it passes)
/// the single fused classify+extract LLM call. Throws [LlmException] straight
/// through so the processing queue can apply its retry/backoff policy.
class Classifier {
  Classifier(this._llm);

  final LlmProvider _llm;

  Future<ClassificationOutcome> classify({
    required String sender,
    required String content,
    required List<Bank> banks,
    required String currency,
  }) async {
    if (gateBanks(sender, content, banks).isEmpty) {
      return const ClassificationOutcome.ignored();
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
    );
  }
}
