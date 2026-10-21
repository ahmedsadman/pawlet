import 'dart:math' as math;

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import '../data/banks_repository.dart';
import '../data/delivery_health_store.dart';
import '../data/sms_repository.dart';
import '../models/sms_record.dart';
import 'battery_prompt_policy.dart';
import 'classification/sender_matcher.dart';
import 'permissions.dart';

/// One phone-inbox message, reduced to what miss detection needs.
class RecentInboxMessage {
  const RecentInboxMessage({
    required this.sender,
    required this.content,
    required this.receivedAt,
    required this.sentAt,
  });

  final String sender;
  final String content;

  /// `Telephony.Sms.DATE`: when the phone received it (epoch ms).
  final int receivedAt;

  /// `Telephony.Sms.DATE_SENT`: the carrier's stamp, the same clock the live
  /// receiver stores. 0 when the SMS app didn't write it.
  final int sentAt;
}

/// Reads inbox messages by receipt time. An interface so detection is tested
/// against a canned list.
abstract class RecentInboxReader {
  /// Messages received in `(afterMs, untilMs]`. Throws on a query failure, so
  /// the caller can tell "nothing new" from "couldn't look".
  Future<List<RecentInboxMessage>> readReceivedBetween(
    int afterMs,
    int untilMs,
  );
}

/// [RecentInboxReader] backed by the telephony plugin. Requires READ_SMS.
class TelephonyRecentInboxReader implements RecentInboxReader {
  TelephonyRecentInboxReader({Telephony? telephony})
    : _telephony = telephony ?? Telephony.instance;

  final Telephony _telephony;

  @override
  Future<List<RecentInboxMessage>> readReceivedBetween(
    int afterMs,
    int untilMs,
  ) async {
    final raw = await _telephony.getInboxSms(
      columns: const [
        SmsColumn.ADDRESS,
        SmsColumn.BODY,
        SmsColumn.DATE,
        SmsColumn.DATE_SENT,
      ],
      filter: SmsFilter.where(SmsColumn.DATE)
          .greaterThan('$afterMs')
          .and(SmsColumn.DATE)
          .lessThanOrEqualTo('$untilMs'),
    );
    return [
      for (final m in raw)
        RecentInboxMessage(
          sender: m.address ?? '',
          content: m.body ?? '',
          receivedAt: m.date ?? 0,
          sentAt: m.dateSent ?? 0,
        ),
    ];
  }
}

/// Finds bank SMS that reached the phone inbox but never reached Pawlet: the
/// receiver didn't run, which is what an OS stopping the app looks like. The
/// default SMS app writes the inbox whether or not Pawlet runs, so an inbox
/// message with no `sms_records` row is a miss.
///
/// UI isolate only. Never throws: a failed scan records nothing and keeps the
/// watermark, so the next one re-checks the same range.
class MissedSmsDetector {
  MissedSmsDetector({
    required this._inbox,
    required SmsRepository smsRepository,
    required BanksRepository banksRepository,
    required this._store,
    this._hasSms = AppPermissions.hasSms,
    int Function()? clock,
  }) : _sms = smsRepository,
       _banks = banksRepository,
       _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final RecentInboxReader _inbox;
  final SmsRepository _sms;
  final BanksRepository _banks;
  final DeliveryHealthStore _store;
  final Future<bool> Function() _hasSms;
  final int Function() _clock;

  /// Minimum time between scans.
  static const Duration scanGap = Duration(hours: 8);

  /// A message this recent may still be on its way through the receiver's
  /// background isolate, so it can't count as missed yet.
  static const Duration receiverGrace = Duration(minutes: 2);

  /// The furthest back a scan reads. Kept under the 7-day retention of ignored
  /// rows (`kIgnoredRetention`), so a pruned capture can't read as a miss.
  static const Duration lookbackCap = Duration(days: 6);

  /// Matches whitespace in SMS bodies. Whitespace is ignored when comparing
  /// inbox to stored bodies because the live receiver trims each multipart
  /// segment after the first while the inbox keeps them as sent.
  static final _whitespace = RegExp(r'\s+');

  Future<void> scanIfDue() async {
    try {
      final watermark = _store.watermark;
      if (watermark == null) return;
      final now = _clock();
      final last = _store.lastScanAt;
      // A clock set back puts lastScanAt in the future; treat that as due
      // rather than stalling until wall time catches up.
      if (last != null && last <= now && now - last < scanGap.inMilliseconds) {
        return;
      }
      // When permission is revoked, move the watermark forward so messages
      // received during the gap don't later count as misses.
      if (!await _hasSms()) {
        final gracedNow = now - receiverGrace.inMilliseconds;
        if (gracedNow > watermark) await _store.setWatermark(gracedNow);
        return;
      }

      final after = math.max(watermark, now - lookbackCap.inMilliseconds);
      final until = now - receiverGrace.inMilliseconds;
      final misses = <int>[];
      if (until > after) {
        final messages = await _inbox.readReceivedBetween(after, until);
        final banks = await _banks.list();
        // Some OEM SMS apps write duplicate inbox rows; count each message once.
        final seen = <String>{};
        for (final m in messages) {
          final sender = m.sender.trim();
          final content = normalizeSmsContent(m.content);
          // No DATE_SENT means no clock shared with the receiver: skipped
          // rather than guessed at.
          if (sender.isEmpty || content.isEmpty || m.sentAt <= 0) continue;
          if (!hasGateBank(sender, content, banks)) continue;

          final strippedContent = content.replaceAll(_whitespace, '');
          final key = '$sender|${m.sentAt}|$strippedContent';
          if (!seen.add(key)) continue;

          final storedContents = await _sms.contentsNear(
            sender: sender,
            timestamp: m.sentAt,
          );
          final captured = storedContents.any((stored) {
            final strippedStored = stored.replaceAll(_whitespace, '');
            return strippedStored == strippedContent;
          });
          if (!captured) misses.add(m.receivedAt);
        }
      }

      // Write order is watermark → misses → lastScanAt: under-count is the
      // safe direction if the process dies mid-write.
      final cutoff = now - BatteryPromptPolicy.missWindow.inMilliseconds;
      if (until > watermark) await _store.setWatermark(until);
      await _store.setMissedAt([
        for (final t in [..._store.missedAt, ...misses])
          if (t >= cutoff) t,
      ]);
      await _store.setLastScanAt(now);
    } catch (e) {
      if (kDebugMode) debugPrint('missed sms: scan failed: $e');
    }
  }
}
