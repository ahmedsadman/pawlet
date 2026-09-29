import 'package:another_telephony/telephony.dart';

/// One message read from the device SMS inbox, reduced to the three fields the
/// import needs — which are also exactly the three that form the `sms_records`
/// dedup key.
class InboxMessage {
  const InboxMessage({
    required this.sender,
    required this.content,
    required this.timestamp,
  });

  final String sender;
  final String content;

  /// Epoch milliseconds the message was received.
  final int timestamp;
}

/// Reads the device SMS inbox. An interface so the import can be tested against
/// a canned list, with no platform channel in play.
abstract class InboxReader {
  Future<List<InboxMessage>> readAll();
}

/// [InboxReader] backed by the telephony plugin's content-provider query.
///
/// Requires READ_SMS. A query failure yields an empty list rather than throwing:
/// the import then reports "0 messages" instead of surfacing a platform
/// exception to a user who was just offered a convenience feature.
class TelephonyInboxReader implements InboxReader {
  TelephonyInboxReader({Telephony? telephony})
    : _telephony = telephony ?? Telephony.instance;

  final Telephony _telephony;

  @override
  Future<List<InboxMessage>> readAll() async {
    final List<SmsMessage> raw;
    try {
      raw = await _telephony.getInboxSms(
        // Only the dedup-key columns: the query returns the whole inbox, so
        // every extra projection is paid per row.
        columns: const [SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
        sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.ASC)],
      );
    } catch (_) {
      return const [];
    }
    return [
      for (final m in raw)
        InboxMessage(
          sender: m.address ?? '',
          content: m.body ?? '',
          timestamp: m.date ?? 0,
        ),
    ];
  }
}
