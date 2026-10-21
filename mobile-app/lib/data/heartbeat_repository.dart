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
    this.llm,
  });

  final String day;
  final int appVersionCode;
  final bool opened;
  final bool alive;
  final String? llm;

  factory HeartbeatRow.fromDbMap(Map<String, Object?> m) => HeartbeatRow(
    day: m['day'] as String,
    appVersionCode: m['app_version_code'] as int,
    opened: m['opened'] == 1,
    alive: m['alive'] == 1,
    llm: m['llm_group'] as String?,
  );

  Map<String, Object> toJson() {
    final json = {
      'day': day,
      'appVersionCode': appVersionCode,
      'opened': opened,
      'alive': alive,
    };
    if (llm != null) json['llm'] = llm!;
    return json;
  }
}

/// The heartbeat log: per UTC day, whether the app ran and whether it was
/// opened, under the build running, and the install's LLM group, plus the
/// reporter's bookkeeping. Kept for the same window as the local-model stats.
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
  /// The LLM group is stored and a change bumps `updated_at`.
  ///
  /// Plain insert/update rather than upsert: ON CONFLICT DO UPDATE needs
  /// SQLite 3.24 (Android 11 / API 30+), but minSdk is 24 (Android 7).
  Future<void> mark({
    required bool opened,
    required int nowMs,
    required int appVersionCode,
    required String? llmGroup,
  }) => _db.transaction((txn) async {
    final day = utcDay(nowMs);
    final existing = await txn.query(
      _table,
      columns: ['app_version_code', 'opened', 'alive', 'llm_group'],
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
        'llm_group': llmGroup,
        'updated_at': nowMs,
      });
    } else {
      final old = existing.single;
      final oldOpened = old['opened'] == 1;
      final newOpened = oldOpened || opened;
      final oldAlive = old['alive'] == 1;
      final oldVersion = old['app_version_code'] as int;
      final oldGroup = old['llm_group'] as String?;

      // Update only when changed.
      if (oldVersion != appVersionCode ||
          oldOpened != newOpened ||
          !oldAlive ||
          oldGroup != llmGroup) {
        await txn.update(
          _table,
          {
            'app_version_code': appVersionCode,
            'opened': newOpened ? 1 : 0,
            'alive': 1,
            'llm_group': llmGroup,
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

  /// Rows never acknowledged or changed since, on or after [minDay] and on or
  /// before [maxDay]. When more than [limit] qualify the oldest are left for a
  /// later flush. Returned oldest first.
  Future<List<HeartbeatRow>> unreported({
    required String minDay,
    required String maxDay,
    required int limit,
  }) async {
    final rows = await _db.query(
      _table,
      where:
          'day >= ? AND day <= ? AND (reported_at IS NULL OR updated_at > reported_at)',
      whereArgs: [minDay, maxDay],
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
      final where = r.llm == null
          ? 'day = ? AND app_version_code = ? AND opened = ? AND alive = ? '
                'AND llm_group IS NULL'
          : 'day = ? AND app_version_code = ? AND opened = ? AND alive = ? '
                'AND llm_group = ?';
      final whereArgs = r.llm == null
          ? [r.day, r.appVersionCode, r.opened ? 1 : 0, r.alive ? 1 : 0]
          : [r.day, r.appVersionCode, r.opened ? 1 : 0, r.alive ? 1 : 0, r.llm];
      batch.update(
        _table,
        {'reported_at': reportedAt},
        where: where,
        whereArgs: whereArgs,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Deletes rows for days before [minDay], reported or not.
  Future<void> pruneBefore(String minDay) async {
    await _db.rawDelete('DELETE FROM $_table WHERE day < ?', [minDay]);
  }

  /// The versionCode of the newest day last acknowledged, or null.
  Future<int?> reportedVersion() =>
      readMetaInt(_db, kHeartbeatReportedVersionKey);

  Future<void> setReportedVersion(int versionCode) =>
      writeMetaInt(_db, kHeartbeatReportedVersionKey, versionCode);
}
