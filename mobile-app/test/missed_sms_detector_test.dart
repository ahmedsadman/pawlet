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
}
