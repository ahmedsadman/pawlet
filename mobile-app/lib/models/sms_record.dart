/// Lifecycle status of a captured SMS as it moves through the processing queue.
enum SmsStatus {
  /// Waiting to be processed (also used while backing off between retries).
  queued,

  /// Currently being processed (Layer-1 gate + LLM call in flight).
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
  llmError('llm_error');

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

/// A single captured SMS and its processing state. `sms_records` doubles as the
/// message store — transactions/bills reference its [id].
class SmsRecord {
  const SmsRecord({
    this.id,
    required this.sender,
    this.contactName,
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
  });

  /// Local DB primary key (null before insert).
  final int? id;

  /// Raw sender as reported by Android (phone number or alphanumeric ID).
  final String sender;

  /// Resolved contact name, or null when unmatched / alphanumeric sender.
  final String? contactName;

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

  bool get isQueued =>
      status == SmsStatus.queued || status == SmsStatus.sending;

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
  }) {
    return SmsRecord(
      id: id ?? this.id,
      sender: sender,
      contactName: contactName,
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
    );
  }

  Map<String, Object?> toDbMap() => {
    'id': id,
    'sender': sender,
    'contact_name': contactName,
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
  };

  factory SmsRecord.fromDbMap(Map<String, Object?> map) => SmsRecord(
    id: map['id'] as int?,
    sender: map['sender'] as String,
    contactName: map['contact_name'] as String?,
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
  );
}
