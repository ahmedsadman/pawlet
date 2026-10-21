import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/banks_repository.dart';
import 'package:pawlet/data/delivery_health_store.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/services/missed_sms_detector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

/// A canned inbox that records every window it was asked for.
class _FakeInbox implements RecentInboxReader {
  _FakeInbox([this.messages = const []]);

  final List<RecentInboxMessage> messages;
  Object? error;
  final List<(int, int)> calls = [];

  @override
  Future<List<RecentInboxMessage>> readReceivedBetween(
    int afterMs,
    int untilMs,
  ) async {
    calls.add((afterMs, untilMs));
    final e = error;
    if (e != null) throw e;
    return messages;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  final now = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
  const body = 'Tk 500.00 debited from A/C **1234';

  late Database db;
  late DeliveryHealthStore store;

  setUp(() async {
    db = await openTestDb();
    await insertBank(db, name: 'EBL', matchers: ['ebl']);
    SharedPreferences.setMockInitialValues({});
    store = DeliveryHealthStore(await SharedPreferences.getInstance());
    await store.setWatermark(now - day);
  });

  tearDown(() => db.close());

  MissedSmsDetector detector(_FakeInbox inbox, {bool hasSms = true}) =>
      MissedSmsDetector(
        inbox: inbox,
        smsRepository: SmsRepository(db),
        banksRepository: BanksRepository(db),
        store: store,
        hasSms: () async => hasSms,
        clock: () => now,
      );

  RecentInboxMessage msg({
    String sender = 'EBL',
    String content = body,
    required int receivedAt,
    int? sentAt,
  }) => RecentInboxMessage(
    sender: sender,
    content: content,
    receivedAt: receivedAt,
    sentAt: sentAt ?? receivedAt - 2000,
  );

  test('an uncaptured bank SMS is a miss, recorded by receipt time', () async {
    final at = now - 3 * hour;
    await detector(_FakeInbox([msg(receivedAt: at)])).scanIfDue();
    expect(store.missedAt, [at]);
  });

  test('a captured SMS is not a miss, within the dedup window', () async {
    final at = now - 3 * hour;
    // The receiver stored the SMSC stamp, a few seconds off DATE_SENT.
    await insertSms(db, sender: 'EBL', content: body, ts: at - 2000 + 3000);
    await detector(_FakeInbox([msg(receivedAt: at)])).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('matches on DATE_SENT, not receipt time', () async {
    // Held at the carrier for hours: receipt is far later than the stamp.
    final sent = now - 10 * hour;
    await insertSms(db, sender: 'EBL', content: body, ts: sent);
    await detector(
      _FakeInbox([msg(receivedAt: now - hour, sentAt: sent)]),
    ).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('normalizes the inbox body before looking it up', () async {
    final at = now - 3 * hour;
    await insertSms(db, sender: 'EBL', content: 'line1\nline2', ts: at - 2000);
    await detector(
      _FakeInbox([msg(content: ' line1\r\nline2 ', receivedAt: at)]),
    ).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('non-bank SMS are ignored', () async {
    await detector(
      _FakeInbox([
        msg(sender: 'Mom', content: 'call me', receivedAt: now - hour),
      ]),
    ).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('rows without DATE_SENT are skipped', () async {
    await detector(
      _FakeInbox([msg(receivedAt: now - hour, sentAt: 0)]),
    ).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('reads from the watermark to now minus the grace', () async {
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls, [(now - day, now - 2 * minute)]);
    expect(store.watermark, now - 2 * minute);
    expect(store.lastScanAt, now);
  });

  test('caps the look-back at 6 days', () async {
    await store.setWatermark(now - 10 * day);
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls.single.$1, now - 6 * day);
  });

  test('no watermark yet means no scan', () async {
    SharedPreferences.setMockInitialValues({});
    store = DeliveryHealthStore(await SharedPreferences.getInstance());
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls, isEmpty);
  });

  test('scans at most once per 8 hours', () async {
    await store.setLastScanAt(now - 7 * hour);
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls, isEmpty);

    await store.setLastScanAt(now - 8 * hour);
    await detector(inbox).scanIfDue();
    expect(inbox.calls, hasLength(1));
  });

  test('no SMS permission means no scan', () async {
    final inbox = _FakeInbox();
    await detector(inbox, hasSms: false).scanIfDue();
    expect(inbox.calls, isEmpty);
    expect(store.lastScanAt, isNull);
  });

  test('a failed read keeps the watermark and allows a retry', () async {
    await store.setMissedAt([now - day]);
    final inbox = _FakeInbox()..error = StateError('provider gone');
    await detector(inbox).scanIfDue();
    expect(store.watermark, now - day);
    expect(store.lastScanAt, isNull);
    expect(store.missedAt, [now - day]);
  });

  test('drops misses older than the window when adding new ones', () async {
    await store.setMissedAt([now - 8 * day, now - 2 * day]);
    final at = now - hour;
    await detector(_FakeInbox([msg(receivedAt: at)])).scanIfDue();
    expect(store.missedAt, [now - 2 * day, at]);
  });

  // Fix 1: multipart SMS false misses
  test('ignores whitespace when matching (multipart trim)', () async {
    final at = now - 3 * hour;
    // Stored body has no space between "from" and "A/C" (multipart trim).
    await insertSms(
      db,
      sender: 'EBL',
      content: 'Tk 500 debited fromA/C **1234',
      ts: at - 2000,
    );
    // Inbox has the space (original SMS).
    await detector(
      _FakeInbox([
        msg(content: 'Tk 500 debited from A/C **1234', receivedAt: at),
      ]),
    ).scanIfDue();
    expect(store.missedAt, isEmpty);
  });

  test('whitespace match: different sender means miss', () async {
    final at = now - 3 * hour;
    await insertSms(db, sender: 'BRAC', content: body, ts: at - 2000);
    await detector(_FakeInbox([msg(receivedAt: at)])).scanIfDue();
    expect(store.missedAt, [at]);
  });

  test('whitespace match: outside dedup window means miss', () async {
    final at = now - 3 * hour;
    // Stored message is 20s off DATE_SENT (beyond kSmsDedupWindow of 15s).
    await insertSms(db, sender: 'EBL', content: body, ts: at - 2000 + 20000);
    await detector(_FakeInbox([msg(receivedAt: at)])).scanIfDue();
    expect(store.missedAt, [at]);
  });

  // Fix 3: SMS-permission gap
  test('no SMS permission moves watermark forward', () async {
    final inbox = _FakeInbox();
    final oldWatermark = now - day;
    await store.setWatermark(oldWatermark);
    await detector(inbox, hasSms: false).scanIfDue();
    expect(inbox.calls, isEmpty);
    expect(store.lastScanAt, isNull);
    // Watermark moves to now - receiverGrace.
    expect(store.watermark, now - 2 * minute);
  });

  // Fix 4: in-scan duplicates
  test('deduplicates identical inbox rows within one scan', () async {
    final at = now - 3 * hour;
    // Two identical inbox rows (OEM SMS app bug).
    await detector(
      _FakeInbox([msg(receivedAt: at), msg(receivedAt: at)]),
    ).scanIfDue();
    expect(store.missedAt, [at]); // Only one miss recorded.
  });

  // Fix 5: backwards clock
  test('backwards clock (lastScanAt > now) means scan is due', () async {
    await store.setLastScanAt(now + hour); // Clock jumped backward.
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls, hasLength(1)); // Scan ran.
  });

  // Fix 6: more tests
  test('records several distinct misses in one scan', () async {
    final at1 = now - 5 * hour;
    final at2 = now - 4 * hour;
    final at3 = now - 3 * hour;
    await detector(
      _FakeInbox([
        msg(receivedAt: at1),
        msg(content: 'Tk 100', receivedAt: at2),
        msg(content: 'Tk 200', receivedAt: at3),
      ]),
    ).scanIfDue();
    expect(store.missedAt, [at1, at2, at3]);
  });

  test('watermark ahead of until (recent) means no inbox read', () async {
    // Watermark is at now - 1 min, which is ahead of until (now - 2 min).
    await store.setWatermark(now - minute);
    final inbox = _FakeInbox();
    await detector(inbox).scanIfDue();
    expect(inbox.calls, isEmpty); // No inbox read.
    expect(store.lastScanAt, now); // But lastScanAt is still updated.
  });
}
