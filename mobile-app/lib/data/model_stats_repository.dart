import 'package:sqflite/sqflite.dart';

import '../models/sms_record.dart';
import 'database.dart';

/// `app_meta` key holding the epoch-ms start time of the last model-stats
/// flush the server acknowledged. Shared by every isolate, like
/// `last_prune_at`, so they all honour one throttle.
const String kModelStatsFlushedAtKey = 'model_stats_flushed_at';

/// `app_meta` key holding the epoch-ms time before which no model-stats
/// flush is attempted, set after a failed upload. Shared by every isolate.
const String kModelStatsRetryAtKey = 'model_stats_retry_at';

/// `app_meta` key holding how many model-stats uploads in a row failed.
/// Shared by every isolate; drives the backoff doubling.
const String kModelStatsFailuresKey = 'model_stats_failures';

/// How many UTC days before today are kept and sent (today is kept too).
///
/// One short of the server's limit (it accepts UTC today − 30 by its own
/// clock): with the phone's clock slightly behind near UTC midnight, the
/// oldest day sent would otherwise fall outside it, and the 400 that follows
/// marks the whole batch sent. Kept and sent share one window, so nothing is
/// stored that could never go out.
const int kModelStatsRetentionDays = 29;

/// The UTC calendar day of [epochMs] as `YYYY-MM-DD` — the `day` key of
/// `model_stats` and of the server contract.
String utcDay(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
}

/// The oldest day still kept and sent at [epochMs]: UTC today minus
/// [kModelStatsRetentionDays]. Exact, because UTC has no DST.
String oldestKeptDay(int epochMs) =>
    utcDay(epochMs - kModelStatsRetentionDays * Duration.millisecondsPerDay);

/// One `model_stats` row as sent to the server.
class ModelStatsRow {
  const ModelStatsRow({
    required this.day,
    required this.appVersionCode,
    required this.accepted,
    required this.declined,
    required this.unavailable,
  });

  final String day;
  final int appVersionCode;
  final int accepted;
  final int declined;
  final int unavailable;

  factory ModelStatsRow.fromDbMap(Map<String, Object?> m) => ModelStatsRow(
    day: m['day'] as String,
    appVersionCode: m['app_version_code'] as int,
    accepted: m['accepted'] as int,
    declined: m['declined'] as int,
    unavailable: m['unavailable'] as int,
  );

  Map<String, Object> toJson() => {
    'day': day,
    'appVersionCode': appVersionCode,
    'accepted': accepted,
    'declined': declined,
    'unavailable': unavailable,
  };
}

/// The local-model stats: how the on-device model judged each live message,
/// tallied per UTC day and app version, plus the reporter's bookkeeping.
class ModelStatsRepository {
  ModelStatsRepository(this._db);

  final Database _db;
  static const _table = AppDatabase.modelStatsTable;

  /// Records [verdict] for message [smsId], counting it at most once ever.
  ///
  /// One transaction: `sms_records.local_verdict` is set only while it is
  /// NULL, and only when that update changed a row is the matching
  /// `model_stats` column incremented (with `updated_at` bumped). A retry, a
  /// reclaimed row or a Retry tap therefore finds the verdict already stored
  /// and adds nothing, and the message stays filed under the UTC day and app
  /// version of its first verdict. Days that fell out of the window are
  /// dropped in the same transaction, which keeps the table bounded even when
  /// no flush gets through. Returns whether it counted.
  Future<bool> recordVerdict(
    int smsId,
    LocalVerdict verdict, {
    required int nowMs,
    required int appVersionCode,
  }) {
    // Safe to interpolate: an enum-controlled column name, never user input.
    final column = verdict.value;
    return _db.transaction<bool>((txn) async {
      final changed = await txn.rawUpdate(
        'UPDATE ${AppDatabase.smsTable} SET local_verdict = ? '
        'WHERE id = ? AND local_verdict IS NULL',
        [verdict.value, smsId],
      );
      if (changed != 1) return false;
      await txn.rawInsert(
        'INSERT INTO $_table (day, app_version_code, $column, updated_at) '
        'VALUES (?, ?, 1, ?) '
        'ON CONFLICT(day, app_version_code) DO UPDATE SET '
        '$column = $column + 1, updated_at = excluded.updated_at',
        [utcDay(nowMs), appVersionCode, nowMs],
      );
      await txn.rawDelete('DELETE FROM $_table WHERE day < ?', [
        oldestKeptDay(nowMs),
      ]);
      return true;
    });
  }

  /// Rows never acknowledged or changed since (`reported_at IS NULL OR
  /// updated_at > reported_at`) on or after [minDay]. When more than [limit]
  /// qualify the oldest are left for a later flush. Returned oldest first.
  Future<List<ModelStatsRow>> unreported({
    required String minDay,
    required int limit,
  }) async {
    final rows = await _db.query(
      _table,
      where: 'day >= ? AND (reported_at IS NULL OR updated_at > reported_at)',
      whereArgs: [minDay],
      orderBy: 'day DESC, app_version_code DESC',
      limit: limit,
    );
    return rows.reversed.map(ModelStatsRow.fromDbMap).toList();
  }

  /// Stamps `reported_at = reportedAt` on each of [rows] whose counts still
  /// equal what was sent. A row incremented while the request was in flight
  /// keeps its old stamp, so it qualifies for the next flush.
  Future<void> markReported(List<ModelStatsRow> rows, int reportedAt) async {
    final batch = _db.batch();
    for (final r in rows) {
      batch.update(
        _table,
        {'reported_at': reportedAt},
        where:
            'day = ? AND app_version_code = ? '
            'AND accepted = ? AND declined = ? AND unavailable = ?',
        whereArgs: [
          r.day,
          r.appVersionCode,
          r.accepted,
          r.declined,
          r.unavailable,
        ],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Deletes rows for days before [minDay], reported or not.
  Future<void> pruneBefore(String minDay) async {
    await _db.rawDelete('DELETE FROM $_table WHERE day < ?', [minDay]);
  }

  /// Start time of the last acknowledged flush (any isolate), or null.
  Future<int?> flushedAt() => _metaInt(_db, kModelStatsFlushedAtKey);

  Future<void> setFlushedAt(int epochMs) =>
      _setMetaInt(_db, kModelStatsFlushedAtKey, epochMs);

  /// Earliest time the next flush may be attempted (any isolate), or null
  /// when no failure is being backed off.
  Future<int?> retryAt() => _metaInt(_db, kModelStatsRetryAtKey);

  /// Consecutive failed uploads (any isolate); 0 when none.
  Future<int> failures() async =>
      await _metaInt(_db, kModelStatsFailuresKey) ?? 0;

  /// Counts one more failed upload and sets the retry time to
  /// `retryAtFor(failures)`, `failures` being the new count. One transaction,
  /// so failures in two isolates are both counted.
  Future<void> recordFailure(int Function(int failures) retryAtFor) =>
      _db.transaction((txn) async {
        final failures = (await _metaInt(txn, kModelStatsFailuresKey) ?? 0) + 1;
        await _setMetaInt(txn, kModelStatsFailuresKey, failures);
        await _setMetaInt(txn, kModelStatsRetryAtKey, retryAtFor(failures));
      });

  /// Forgets past failures: no retry time, a failure count of 0.
  Future<void> clearBackoff() async {
    await _db.delete(
      AppDatabase.metaTable,
      where: 'key IN (?, ?)',
      whereArgs: [kModelStatsRetryAtKey, kModelStatsFailuresKey],
    );
  }

  static Future<int?> _metaInt(DatabaseExecutor db, String key) async {
    final rows = await db.query(
      AppDatabase.metaTable,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as int?;
  }

  static Future<void> _setMetaInt(
    DatabaseExecutor db,
    String key,
    int value,
  ) async {
    await db.insert(AppDatabase.metaTable, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
