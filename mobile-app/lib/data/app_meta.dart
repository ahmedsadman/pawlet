import 'package:sqflite/sqflite.dart';

import 'database.dart';

/// Reads an integer from `app_meta`, or null when the key is absent.
Future<int?> readMetaInt(DatabaseExecutor db, String key) async {
  final rows = await db.query(
    AppDatabase.metaTable,
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [key],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.first['value'] as int?;
}

/// Writes an integer to `app_meta`, replacing any previous value.
Future<void> writeMetaInt(DatabaseExecutor db, String key, int value) async {
  await db.insert(AppDatabase.metaTable, {
    'key': key,
    'value': value,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
}

/// One upload's throttle and backoff stamps in `app_meta`, shared by every
/// isolate so they all honour one schedule.
class UploadSchedule {
  const UploadSchedule(
    this._db, {
    required this.flushedAtKey,
    required this.retryAtKey,
    required this.failuresKey,
  });

  final Database _db;
  final String flushedAtKey;
  final String retryAtKey;
  final String failuresKey;

  /// Start time of the last acknowledged flush (any isolate), or null.
  Future<int?> flushedAt() => readMetaInt(_db, flushedAtKey);

  Future<void> setFlushedAt(int epochMs) =>
      writeMetaInt(_db, flushedAtKey, epochMs);

  /// Earliest time the next flush may be attempted (any isolate), or null
  /// when no failure is being backed off.
  Future<int?> retryAt() => readMetaInt(_db, retryAtKey);

  /// Consecutive failed uploads (any isolate); 0 when none.
  Future<int> failures() async => await readMetaInt(_db, failuresKey) ?? 0;

  /// Counts one more failed upload and sets the retry time to
  /// `retryAtFor(failures)`, `failures` being the new count. One transaction,
  /// so failures in two isolates are both counted.
  Future<void> recordFailure(int Function(int failures) retryAtFor) =>
      _db.transaction((txn) async {
        final failures = (await readMetaInt(txn, failuresKey) ?? 0) + 1;
        await writeMetaInt(txn, failuresKey, failures);
        await writeMetaInt(txn, retryAtKey, retryAtFor(failures));
      });

  /// Forgets past failures: no retry time, a failure count of 0.
  Future<void> clearBackoff() async {
    await _db.delete(
      AppDatabase.metaTable,
      where: 'key IN (?, ?)',
      whereArgs: [retryAtKey, failuresKey],
    );
  }
}
