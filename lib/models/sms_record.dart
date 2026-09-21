/// Lifecycle status of a captured SMS as it moves through the processing queue.
enum SmsStatus {
  /// Waiting to be processed (also used while backing off between retries).
  queued,

  /// Currently being processed (Layer-1 gate + LLM call in flight).
  sending,

  /// Processed — categorized and written (or deliberately ignored).
  success,

  /// Gave up after the maximum number of attempts (or a fatal error).
  failure;

  static SmsStatus fromName(String value) => SmsStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => SmsStatus.queued,
  );
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
  );
}
