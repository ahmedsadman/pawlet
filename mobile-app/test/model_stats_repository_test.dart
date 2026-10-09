import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/model_stats_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late ModelStatsRepository repo;
  var seq = 0;

  /// 2026-10-10 12:00 UTC.
  final now = DateTime.utc(2026, 10, 10, 12).millisecondsSinceEpoch;
  const window = '2026-09-11'; // oldestKeptDay(now)

  setUp(() async {
    db = await openTestDb();
    repo = ModelStatsRepository(db);
    seq = 0;
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  /// A live message mid-processing, as `_processOne` holds it.
  Future<int> message() => insertSms(
    db,
    sender: 'CHK',
    content: 'msg ${seq++}',
    ts: now,
    status: 'processing',
  );

  Future<int> seed(
    String day, {
    int version = 21,
    int accepted = 1,
    int declined = 0,
    int unavailable = 0,
    int updatedAt = 0,
    int? reportedAt,
  }) => db.insert('model_stats', {
    'day': day,
    'app_version_code': version,
    'accepted': accepted,
    'declined': declined,
    'unavailable': unavailable,
    'updated_at': updatedAt,
    'reported_at': reportedAt,
  });

  Future<List<Map<String, Object?>>> statsRows() =>
      db.query('model_stats', orderBy: 'day, app_version_code');

  Future<String?> verdictOf(int id) async =>
      (await db.query(
            'sms_records',
            where: 'id = ?',
            whereArgs: [id],
          )).single['local_verdict']
          as String?;

  group('utcDay', () {
    test('formats the UTC calendar day, zero-padded', () {
      expect(
        utcDay(DateTime.utc(2026, 1, 5, 23, 59, 59).millisecondsSinceEpoch),
        '2026-01-05',
      );
      expect(
        utcDay(DateTime.utc(2026, 1, 6).millisecondsSinceEpoch),
        '2026-01-06',
      );
    });

    // One day inside the server's accepted window (UTC today − 30), so a
    // phone clock slightly behind the server's near midnight still fits.
    test('the window keeps today and the 29 days before it', () {
      expect(oldestKeptDay(now), window);
    });
  });

  group('recordVerdict', () {
    test('counts the first verdict and stamps the message', () async {
      final id = await message();

      final counted = await repo.recordVerdict(
        id,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );

      expect(counted, isTrue);
      expect(await verdictOf(id), 'accepted');
      final s = (await statsRows()).single;
      expect(s['day'], '2026-10-10');
      expect(s['app_version_code'], 21);
      expect([s['accepted'], s['declined'], s['unavailable']], [1, 0, 0]);
      expect(s['updated_at'], now);
      expect(s['reported_at'], isNull);
    });

    test('counts a message once, whatever comes later', () async {
      final id = await message();
      await repo.recordVerdict(
        id,
        LocalVerdict.declined,
        nowMs: now,
        appVersionCode: 21,
      );

      final again = await repo.recordVerdict(
        id,
        LocalVerdict.accepted,
        nowMs: now + 1000,
        appVersionCode: 22,
      );

      expect(again, isFalse);
      expect(await verdictOf(id), 'declined');
      final s = (await statsRows()).single;
      expect(s['app_version_code'], 21);
      expect([s['accepted'], s['declined'], s['unavailable']], [0, 1, 0]);
      expect(s['updated_at'], now);
    });

    test('adds up within a day and version and bumps updated_at', () async {
      final a = await message();
      final b = await message();
      final c = await message();
      await repo.recordVerdict(
        a,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );
      await repo.recordVerdict(
        b,
        LocalVerdict.accepted,
        nowMs: now + 5,
        appVersionCode: 21,
      );
      await repo.recordVerdict(
        c,
        LocalVerdict.unavailable,
        nowMs: now + 9,
        appVersionCode: 21,
      );

      final s = (await statsRows()).single;
      expect([s['accepted'], s['declined'], s['unavailable']], [2, 0, 1]);
      expect(s['updated_at'], now + 9);
    });

    test('files verdicts under their UTC day and app version', () async {
      final a = await message();
      final b = await message();
      final c = await message();
      await repo.recordVerdict(
        a,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );
      await repo.recordVerdict(
        b,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 22,
      );
      await repo.recordVerdict(
        c,
        LocalVerdict.accepted,
        nowMs: DateTime.utc(2026, 10, 11, 0, 0, 1).millisecondsSinceEpoch,
        appVersionCode: 21,
      );

      expect(
        (await statsRows()).map((r) => '${r['day']}/${r['app_version_code']}'),
        ['2026-10-10/21', '2026-10-10/22', '2026-10-11/21'],
      );
    });

    test('an unknown message counts nothing', () async {
      final counted = await repo.recordVerdict(
        999,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );

      expect(counted, isFalse);
      expect(await statsRows(), isEmpty);
    });

    test('drops days that fell out of the 29-day window', () async {
      await seed('2026-09-10');
      await seed(window);
      final id = await message();

      await repo.recordVerdict(
        id,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );

      expect((await statsRows()).map((r) => r['day']), [window, '2026-10-10']);
    });
  });

  group('unreported', () {
    test('returns never-sent and changed rows, oldest first', () async {
      await seed('2026-10-08', updatedAt: 10);
      await seed('2026-10-09', updatedAt: 10, reportedAt: 10);
      await seed('2026-10-10', updatedAt: 20, reportedAt: 10);

      final rows = await repo.unreported(minDay: window, limit: 31);

      expect(rows.map((r) => r.day), ['2026-10-08', '2026-10-10']);
    });

    test('skips days before minDay', () async {
      await seed('2026-09-09');
      await seed(window);

      final rows = await repo.unreported(minDay: window, limit: 31);

      expect(rows.map((r) => r.day), [window]);
    });

    test('keeps the newest rows when over the limit', () async {
      for (var d = 1; d <= 5; d++) {
        await seed('2026-10-0$d');
      }

      final rows = await repo.unreported(minDay: window, limit: 3);

      expect(rows.map((r) => r.day), [
        '2026-10-03',
        '2026-10-04',
        '2026-10-05',
      ]);
    });

    test('serialises to the server contract', () async {
      await seed('2026-10-10', accepted: 4, declined: 2, unavailable: 1);

      final row = (await repo.unreported(minDay: window, limit: 31)).single;

      expect(row.toJson(), {
        'day': '2026-10-10',
        'appVersionCode': 21,
        'accepted': 4,
        'declined': 2,
        'unavailable': 1,
      });
    });
  });

  group('markReported', () {
    test('stamps rows whose counts did not move', () async {
      await seed('2026-10-09', updatedAt: 5);
      await seed('2026-10-10', updatedAt: 5);
      final rows = await repo.unreported(minDay: window, limit: 31);

      await repo.markReported(rows, 100);

      expect((await statsRows()).map((r) => r['reported_at']), [100, 100]);
      expect(await repo.unreported(minDay: window, limit: 31), isEmpty);
    });

    test('leaves a row that changed after it was read', () async {
      final a = await message();
      await repo.recordVerdict(
        a,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );
      final sent = await repo.unreported(minDay: window, limit: 31);
      // Lands while the request is in flight, in the same millisecond.
      final b = await message();
      await repo.recordVerdict(
        b,
        LocalVerdict.accepted,
        nowMs: now,
        appVersionCode: 21,
      );

      await repo.markReported(sent, now);

      expect((await statsRows()).single['reported_at'], isNull);
      final pending = await repo.unreported(minDay: window, limit: 31);
      expect(pending.single.accepted, 2);
    });
  });

  test('pruneBefore deletes only older days', () async {
    await seed('2026-09-09');
    await seed(window);

    await repo.pruneBefore(window);

    expect((await statsRows()).map((r) => r['day']), [window]);
  });

  test('flushedAt round-trips through app_meta', () async {
    expect(await repo.flushedAt(), isNull);

    await repo.setFlushedAt(now);

    expect(await repo.flushedAt(), now);
    final meta = await db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [kModelStatsFlushedAtKey],
    );
    expect(meta.single['value'], now);
  });
}
