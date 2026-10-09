import 'finance/transaction.dart';

/// Lifecycle status of a captured SMS as it moves through the processing queue.
enum SmsStatus {
  /// Waiting to be processed (also used while backing off between retries).
  queued,

  /// Being classified on-device: the Layer-1 gate and the local model. NOT
  /// exclusive — any number of rows may be `processing` across isolates at
  /// once, because no network call and no rate limit is involved. Contrast
  /// [sending], which is capped at one row process-wide.
  processing,

  /// An LLM call is in flight. Exactly one row process-wide holds this
  /// (see [SmsRepository.acquireLlmSlot]).
  sending,

  /// Processed — categorized and written to a finance record.
  success,

  /// Processed, deliberately not a financial record; pruned after a short
  /// retention. Invisible in History (tagged with an internal [IgnoreReason]).
  ignored,

  /// Gave up after the maximum number of attempts (or a fatal error).
  failure;

  static SmsStatus fromName(String value) => SmsStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => SmsStatus.queued,
  );
}

/// Why a processed SMS was ignored (internal only — never shown in the UI,
/// read via ADB/debug). DB stores the snake_case [value].
enum IgnoreReason {
  /// Layer-1 sender/card gate rejected it; nothing ran.
  gated('gated'),

  /// The on-device model confidently classified it as not financial (no LLM).
  localNone('local_none'),

  /// The on-device model ran but did not clear the confidence gate. Only the
  /// bulk inbox import produces this: the live pipeline would fall back to the
  /// LLM, whereas the import is on-device only and drops the message instead.
  localLowConfidence('local_low_confidence'),

  /// The on-device model never produced a prediction (it failed to load, or the
  /// run itself failed), so nothing judged this message. Also import-only, and
  /// kept apart from [localLowConfidence] because the two call for opposite
  /// diagnoses: a handful of these is a hard message, a whole inbox of them is
  /// a broken model.
  localUnavailable('local_unavailable'),

  /// The LLM ran and classified it as not financial.
  llmNone('llm_none'),

  /// The LLM classified it as financial but no finance row was written
  /// (missing metadata, unmatched card, or a duplicate).
  noRecord('no_record');

  const IgnoreReason(this.value);
  final String value;

  static IgnoreReason? fromValue(String? v) {
    for (final r in IgnoreReason.values) {
      if (r.value == v) return r;
    }
    return null;
  }
}

/// Why a processing attempt failed permanently, surfaced as a short History
/// hint. DB stores the snake_case [value].
enum FailureReason {
  /// Exhausted the retry budget on a retryable error.
  retryExhausted('retry_exhausted'),

  /// A fatal (non-retryable) LLM error.
  llmError('llm_error'),

  /// The on-device model ran but its output could not be turned into a record
  /// — no amount span, an unparseable number, or a foreign currency with no
  /// conversion path — and this install has no LLM to fall back to. Recoverable
  /// by design: adding an OpenRouter key and hitting Retry reprocesses the row.
  localOnly('local_only');

  const FailureReason(this.value);
  final String value;

  static FailureReason? fromValue(String? v) {
    for (final r in FailureReason.values) {
      if (r.value == v) return r;
    }
    return null;
  }
}

/// Which engine parsed a processed SMS: the on-device model or the cloud LLM.
/// Null on rows processed before this column existed, or gate-ignored rows.
/// DB stores the [value].
enum ParseSource {
  local('local'),
  llm('llm');

  const ParseSource(this.value);
  final String value;

  static ParseSource? fromValue(String? v) {
    for (final s in ParseSource.values) {
      if (s.value == v) return s;
    }
    return null;
  }
}

/// What the on-device model made of a message the live pipeline ran it on.
/// Recorded once per message in `sms_records.local_verdict` and tallied in
/// `model_stats` for the local-model stats. DB stores the [value], which is
/// also the name of the `model_stats` column it is counted in.
enum LocalVerdict {
  /// The model's output cleared the confidence gate (financial or not); the
  /// LLM is never called for this message.
  accepted('accepted'),

  /// The model ran but did not clear the gate; the message goes to the LLM.
  declined('declined'),

  /// The model produced no prediction (failed to load, or the run failed).
  unavailable('unavailable');

  const LocalVerdict(this.value);
  final String value;
}

/// A single captured SMS and its processing state. `sms_records` doubles as the
/// message store — transactions/bills reference its [id].
class SmsRecord {
  const SmsRecord({
    this.id,
    required this.sender,
    required this.content,
    required this.timestamp,
    this.status = SmsStatus.queued,
    this.attempts = 0,
    this.lastError,
    this.updatedAt = 0,
    this.nextAttemptAt,
    this.category,
    this.processedAt,
    this.ignoreReason,
    this.failureReason,
    this.parseSource,
    this.needsLlm = false,
    this.transactionType,
  });

  /// Local DB primary key (null before insert).
  final int? id;

  /// Raw sender as reported by Android (phone number or alphanumeric ID).
  final String sender;

  final String content;

  /// Epoch milliseconds when the SMS was received (NOT when it is processed).
  final int timestamp;

  final SmsStatus status;
  final int attempts;
  final String? lastError;

  /// Epoch milliseconds of the last status change (drives History ordering).
  final int updatedAt;

  /// Epoch milliseconds before which a queued row must not be retried.
  /// Null means due immediately.
  final int? nextAttemptAt;

  /// Classification label once processed: `transaction` | `bill` | `ignored`.
  final String? category;

  /// Epoch milliseconds when processing completed, or null.
  final int? processedAt;

  /// Internal debugging tag for [SmsStatus.ignored] rows (not user-facing).
  final IgnoreReason? ignoreReason;

  /// Why a [SmsStatus.failure] row failed (drives the short History hint).
  final FailureReason? failureReason;

  /// Which engine parsed this row (on-device model vs LLM), or null when the
  /// Layer-1 gate rejected it before any model ran (and for pre-v4 rows).
  final ParseSource? parseSource;

  /// True once the on-device model has run on this exact content and declined
  /// it, so the row can only be resolved by the LLM. Set when a pass reaches
  /// Layer 3 but cannot run it (offline, or the single LLM slot is busy); read
  /// by later passes to skip an inference whose answer is already known.
  /// Never cleared — `content` is immutable, so the verdict is stable.
  final bool needsLlm;

  /// Transient (not persisted on `sms_records`): the type of the backing
  /// transaction row, joined in for History display so a transaction shows its
  /// subcategory (Income/Expense/Transfer) instead of the generic label. Null
  /// for bills, failures, and rows read without the join.
  final TxType? transactionType;

  bool get isQueued =>
      status == SmsStatus.queued ||
      status == SmsStatus.processing ||
      status == SmsStatus.sending;

  SmsRecord copyWith({
    int? id,
    SmsStatus? status,
    int? attempts,
    String? lastError,
    int? updatedAt,
    int? nextAttemptAt,
    String? category,
    int? processedAt,
    IgnoreReason? ignoreReason,
    FailureReason? failureReason,
    ParseSource? parseSource,
    bool? needsLlm,
    TxType? transactionType,
  }) {
    return SmsRecord(
      id: id ?? this.id,
      sender: sender,
      content: content,
      timestamp: timestamp,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
      nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
      category: category ?? this.category,
      processedAt: processedAt ?? this.processedAt,
      ignoreReason: ignoreReason ?? this.ignoreReason,
      failureReason: failureReason ?? this.failureReason,
      parseSource: parseSource ?? this.parseSource,
      needsLlm: needsLlm ?? this.needsLlm,
      transactionType: transactionType ?? this.transactionType,
    );
  }

  Map<String, Object?> toDbMap() => {
    'id': id,
    'sender': sender,
    'content': content,
    'timestamp': timestamp,
    'status': status.name,
    'attempts': attempts,
    'last_error': lastError,
    'updated_at': updatedAt,
    'next_attempt_at': nextAttemptAt,
    'category': category,
    'processed_at': processedAt,
    'ignore_reason': ignoreReason?.value,
    'failure_reason': failureReason?.value,
    'parse_source': parseSource?.value,
    'needs_llm': needsLlm ? 1 : 0,
  };

  factory SmsRecord.fromDbMap(Map<String, Object?> map) => SmsRecord(
    id: map['id'] as int?,
    sender: map['sender'] as String,
    content: map['content'] as String,
    timestamp: map['timestamp'] as int,
    status: SmsStatus.fromName(map['status'] as String),
    attempts: map['attempts'] as int? ?? 0,
    lastError: map['last_error'] as String?,
    updatedAt: map['updated_at'] as int? ?? 0,
    nextAttemptAt: map['next_attempt_at'] as int?,
    category: map['category'] as String?,
    processedAt: map['processed_at'] as int?,
    ignoreReason: IgnoreReason.fromValue(map['ignore_reason'] as String?),
    failureReason: FailureReason.fromValue(map['failure_reason'] as String?),
    parseSource: ParseSource.fromValue(map['parse_source'] as String?),
    needsLlm: (map['needs_llm'] as int? ?? 0) != 0,
    // `tx_type` is present only when a query LEFT JOINs the transactions table
    // (History); absent elsewhere, in which case it stays null.
    transactionType: map['tx_type'] == null
        ? null
        : TxType.fromValue(map['tx_type'] as String),
  );
}
