import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/heartbeat_repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late HeartbeatRepository repo;

  /// 2026-10-13 12:00 UTC.
  final now = DateTime.utc(2026, 10, 13, 12).millisecondsSinceEpoch;
  const day = Duration.millisecondsPerDay;

  setUp(() async {
    db = await openTestDb();
    repo = HeartbeatRepository(db);
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Future<Map<String, Object?>> row(String d) async => (await db.query(
    'heartbeat_days',
    where: 'day = ?',
    whereArgs: [d],
  )).single;

  test('marks today alive, and opened only when asked', () async {
    await repo.mark(opened: false, nowMs: now, appVersionCode: 28);
    var r = await row('2026-10-13');
    expect([r['opened'], r['alive'], r['app_version_code']], [0, 1, 28]);
    expect(r['updated_at'], now);

    await repo.mark(opened: true, nowMs: now + 1, appVersionCode: 28);
    r = await row('2026-10-13');
    expect([r['opened'], r['alive']], [1, 1]);
    expect(r['updated_at'], now + 1);
  });

  test('flags are sticky and an unchanged mark leaves updated_at', () async {
    await repo.mark(opened: true, nowMs: now, appVersionCode: 28);
    await repo.mark(opened: false, nowMs: now + 5, appVersionCode: 28);
    final r = await row('2026-10-13');
    expect(r['opened'], 1);
    expect(r['updated_at'], now);
  });

  test('the latest version wins within a day', () async {
    await repo.mark(opened: true, nowMs: now, appVersionCode: 27);
    await repo.mark(opened: false, nowMs: now + 5, appVersionCode: 28);
    final r = await row('2026-10-13');
    expect([r['opened'], r['app_version_code']], [1, 28]);
    expect(r['updated_at'], now + 5);
  });

  test('marking prunes days outside the window', () async {
    await db.insert('heartbeat_days', {
      'day': '2026-09-13', // 30 days before: outside the 29-day window
      'app_version_code': 25,
      'alive': 1,
      'updated_at': 1,
    });
    await repo.mark(opened: false, nowMs: now, appVersionCode: 28);
    final days = (await db.query('heartbeat_days')).map((r) => r['day']);
    expect(days, ['2026-10-13']);
  });

  test('unreported returns new and changed rows oldest first', () async {
    await repo.mark(opened: false, nowMs: now - 2 * day, appVersionCode: 27);
    await repo.mark(opened: true, nowMs: now - day, appVersionCode: 28);
    await repo.mark(opened: true, nowMs: now, appVersionCode: 28);

    final first = await repo.unreported(
      minDay: '2026-09-14',
      maxDay: '9999-12-31',
      limit: 31,
    );
    expect(first.map((r) => r.day), ['2026-10-11', '2026-10-12', '2026-10-13']);
    await repo.markReported(first, now + 10);
    expect(
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
      isEmpty,
    );

    await repo.mark(opened: true, nowMs: now + 20, appVersionCode: 29);
    final changed = await repo.unreported(
      minDay: '2026-09-14',
      maxDay: '9999-12-31',
      limit: 31,
    );
    expect(changed.single.appVersionCode, 29);
  });

  test('a row changed mid-upload stays unreported', () async {
    await repo.mark(opened: false, nowMs: now, appVersionCode: 28);
    final sent = await repo.unreported(
      minDay: '2026-09-14',
      maxDay: '9999-12-31',
      limit: 31,
    );
    await repo.mark(opened: true, nowMs: now + 1, appVersionCode: 28);
    await repo.markReported(sent, now + 2);
    expect(
      (await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      )).single.opened,
      isTrue,
    );
  });

  test('unreported keeps the newest rows when over the limit', () async {
    for (var i = 0; i < 3; i++) {
      await repo.mark(opened: false, nowMs: now - i * day, appVersionCode: 28);
    }
    final rows = await repo.unreported(
      minDay: '2026-09-14',
      maxDay: '9999-12-31',
      limit: 2,
    );
    expect(rows.map((r) => r.day), ['2026-10-12', '2026-10-13']);
  });

  test('unreported excludes days after maxDay', () async {
    await db.insert('heartbeat_days', {
      'day': '2026-10-12',
      'app_version_code': 28,
      'alive': 1,
      'updated_at': now - day,
    });
    await db.insert('heartbeat_days', {
      'day': '2026-10-15',
      'app_version_code': 28,
      'alive': 1,
      'updated_at': now + 2 * day,
    });
    final rows = await repo.unreported(
      minDay: '2026-09-14',
      maxDay: '2026-10-13',
      limit: 31,
    );
    expect(rows.map((r) => r.day), ['2026-10-12']);
  });

  test('toJson matches the server contract', () {
    const r = HeartbeatRow(
      day: '2026-10-13',
      appVersionCode: 28,
      opened: true,
      alive: true,
    );
    expect(r.toJson(), {
      'day': '2026-10-13',
      'appVersionCode': 28,
      'opened': true,
      'alive': true,
    });
  });

  test('pruneBefore deletes old days', () async {
    await db.insert('heartbeat_days', {
      'day': '2026-10-08',
      'app_version_code': 27,
      'alive': 1,
      'updated_at': now - 5 * day,
    });
    await db.insert('heartbeat_days', {
      'day': '2026-10-11',
      'app_version_code': 28,
      'alive': 1,
      'updated_at': now - 2 * day,
    });
    await db.insert('heartbeat_days', {
      'day': '2026-10-13',
      'app_version_code': 28,
      'alive': 1,
      'updated_at': now,
    });
    await repo.pruneBefore('2026-10-11');
    final days = (await db.query('heartbeat_days')).map((r) => r['day']);
    expect(days, ['2026-10-11', '2026-10-13']);
  });

  test('deleteAll empties the log', () async {
    await repo.mark(opened: true, nowMs: now, appVersionCode: 28);
    await repo.deleteAll();
    expect(await db.query('heartbeat_days'), isEmpty);
  });

  test('remembers the last acknowledged version', () async {
    expect(await repo.reportedVersion(), isNull);
    await repo.setReportedVersion(28);
    expect(await repo.reportedVersion(), 28);
  });
}
