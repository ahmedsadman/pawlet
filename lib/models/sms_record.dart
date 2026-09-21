import 'dart:convert';

/// Lifecycle status of a captured SMS.
enum SmsStatus {
  /// Waiting to be sent (also used while backing off between retries).
  queued,

  /// Currently being POSTed to the webhook.
  sending,

  /// Delivered — webhook returned a 2xx response.
  success,

  /// Gave up after the maximum number of attempts.
  failure;

  static SmsStatus fromName(String value) => SmsStatus.values.firstWhere(
    (s) => s.name == value,
    orElse: () => SmsStatus.queued,
  );
}

/// A single captured SMS and its delivery state.
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
  });

  /// Local DB primary key (null before insert).
  final int? id;

  /// Raw sender as reported by Android (phone number or alphanumeric ID).
  final String sender;

  /// Resolved contact name, or null when unmatched / alphanumeric sender.
  final String? contactName;

  final String content;

  /// Epoch milliseconds when the SMS was received (NOT when it is sent).
  final int timestamp;

  final SmsStatus status;
  final int attempts;
  final String? lastError;

  /// Epoch milliseconds of the last status change (drives History ordering).
  final int updatedAt;

  /// Epoch milliseconds before which a queued row must not be retried.
  /// Null means due immediately.
  final int? nextAttemptAt;

  bool get isQueued =>
      status == SmsStatus.queued || status == SmsStatus.sending;

  SmsRecord copyWith({
    int? id,
    SmsStatus? status,
    int? attempts,
    String? lastError,
    int? updatedAt,
    int? nextAttemptAt,
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
  );

  /// The exact JSON body sent to the webhook.
  ///
  /// `jsonEncode` escapes [content] automatically — no manual pre-escaping.
  Map<String, Object?> toWebhookJson() => {
    'sender': sender,
    'content': content,
    'timestamp': timestamp,
    'contactName': contactName,
  };

  String toWebhookBody() => jsonEncode(toWebhookJson());
}
