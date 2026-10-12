import 'package:sqflite/sqflite.dart';

import 'app_meta.dart';
import 'database.dart';
import 'model_stats_repository.dart' show oldestKeptDay, utcDay;

/// `app_meta` keys for the heartbeat upload's schedule, shared by every
/// isolate.
const String kHeartbeatFlushedAtKey = 'heartbeat_flushed_at';
const String kHeartbeatRetryAtKey = 'heartbeat_retry_at';
const String kHeartbeatFailuresKey = 'heartbeat_failures';

/// `app_meta` key holding the versionCode of the newest day the server last
/// acknowledged, so a new build is reported without waiting for the throttle.
const String kHeartbeatReportedVersionKey = 'heartbeat_reported_version';

/// One `heartbeat_days` row as sent to the server.
class HeartbeatRow {
  const HeartbeatRow({
    required this.day,
    required this.appVersionCode,
    required this.opened,
    required this.alive,
  });

  final String day;
  final int appVersionCode;
  final bool opened;
  final bool alive;

  factory HeartbeatRow.fromDbMap(Map<String, Object?> m) => HeartbeatRow(
    day: m['day'] as String,
    appVersionCode: m['app_version_code'] as int,
    opened: m['opened'] == 1,
    alive: m['alive'] == 1,
  );

  Map<String, Object> toJson() => {
    'day': day,
    'appVersionCode': appVersionCode,
    'opened': opened,
    'alive': alive,
  };
}

/// The heartbeat log: per UTC day, whether the app ran and whether it was
/// opened, under the build running, plus the reporter's bookkeeping. Kept for
/// the same window as the local-model stats.
class HeartbeatRepository {
  HeartbeatRepository(this._db)
    : schedule = UploadSchedule(
        _db,
        flushedAtKey: kHeartbeatFlushedAtKey,
        retryAtKey: kHeartbeatRetryAtKey,
        failuresKey: kHeartbeatFailuresKey,
      );

  final Database _db;
  static const _table = AppDatabase.heartbeatTable;

  /// The upload's throttle and backoff stamps.
  final UploadSchedule schedule;

  /// Marks today (UTC) alive, and opened when [opened]. Flags only ever turn
  /// on and the version is the running build's. `updated_at` moves only when
  /// the row actually changed, so a repeat mark (every resume) leaves nothing
  /// to report. Days outside the window are dropped in the same transaction.
  ///
  /// Plain insert/update rather than upsert: ON CONFLICT DO UPDATE needs
  /// SQLite 3.24 (Android 11 / API 30+), but minSdk is 24 (Android 7).
  Future<void> mark({
    required bool opened,
    required int nowMs,
    required int appVersionCode,
  }) => _db.transaction((txn) async {
    final day = utcDay(nowMs);
    final existing = await txn.query(
      _table,
      columns: ['app_version_code', 'opened', 'alive'],
      where: 'day = ?',
      whereArgs: [day],
      limit: 1,
    );

    if (existing.isEmpty) {
      await txn.insert(_table, {
        'day': day,
        'app_version_code': appVersionCode,
        'opened': opened ? 1 : 0,
        'alive': 1,
        'updated_at': nowMs,
      });
    } else {
      final old = existing.single;
      final oldOpened = old['opened'] == 1;
      final newOpened = oldOpened || opened;
      final oldAlive = old['alive'] == 1;
      final oldVersion = old['app_version_code'] as int;

      // Update only when changed.
      if (oldVersion != appVersionCode || oldOpened != newOpened || !oldAlive) {
        await txn.update(
          _table,
          {
            'app_version_code': appVersionCode,
            'opened': newOpened ? 1 : 0,
            'alive': 1,
            'updated_at': nowMs,
          },
          where: 'day = ?',
          whereArgs: [day],
        );
      }
    }

    await txn.rawDelete('DELETE FROM $_table WHERE day < ?', [
      oldestKeptDay(nowMs),
    ]);
  });

  /// Rows never acknowledged or changed since, on or after [minDay]. When
  /// more than [limit] qualify the oldest are left for a later flush.
  /// Returned oldest first.
  Future<List<HeartbeatRow>> unreported({
    required String minDay,
    required int limit,
  }) async {
    final rows = await _db.query(
      _table,
      where: 'day >= ? AND (reported_at IS NULL OR updated_at > reported_at)',
      whereArgs: [minDay],
      orderBy: 'day DESC',
      limit: limit,
    );
    return rows.reversed.map(HeartbeatRow.fromDbMap).toList();
  }

  /// Stamps `reported_at = reportedAt` on each of [rows] still equal to what
  /// was sent. A row changed while the request was in flight keeps its old
  /// stamp, so it qualifies for the next flush.
  Future<void> markReported(List<HeartbeatRow> rows, int reportedAt) async {
    final batch = _db.batch();
    for (final r in rows) {
      batch.update(
        _table,
        {'reported_at': reportedAt},
        where: 'day = ? AND app_version_code = ? AND opened = ? AND alive = ?',
        whereArgs: [r.day, r.appVersionCode, r.opened ? 1 : 0, r.alive ? 1 : 0],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Deletes rows for days before [minDay], reported or not.
  Future<void> pruneBefore(String minDay) async {
    await _db.rawDelete('DELETE FROM $_table WHERE day < ?', [minDay]);
  }

  /// Deletes the whole log: the install moved to no-LLM, where nothing may
  /// leave the phone.
  Future<void> deleteAll() async {
    await _db.delete(_table);
  }

  /// The versionCode of the newest day last acknowledged, or null.
  Future<int?> reportedVersion() =>
      readMetaInt(_db, kHeartbeatReportedVersionKey);

  Future<void> setReportedVersion(int versionCode) =>
      writeMetaInt(_db, kHeartbeatReportedVersionKey, versionCode);
}
