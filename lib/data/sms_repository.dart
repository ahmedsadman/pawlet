import 'package:sqflite/sqflite.dart';

import '../models/sms_record.dart';
import 'database.dart';

/// Default page size for History.
const int kHistoryPageSize = 20;

/// How long failed records are retained before [SmsRepository.prune] deletes them.
const Duration kFailureRetention = Duration(days: 30);

/// Labels that appear in History (ignored messages are not shown).
const List<String> kHistoryCategories = ['transaction', 'bill'];

/// CRUD + queue/history queries for captured SMS.
class SmsRepository {
  SmsRepository(this._db);

  final Database _db;
  static const _table = AppDatabase.smsTable;

  /// Inserts a new record, ignoring duplicates (same sender+timestamp+content).
  /// Returns the row id, or null when the SMS was already stored.
  Future<int?> insertIfNew(SmsRecord record) async {
    final map = record.toDbMap()..remove('id');
    final id = await _db.insert(
      _table,
      map,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    return id == 0 ? null : id;
  }

  /// Queued + in-flight records, oldest first (drives the Queue section).
  Future<List<SmsRecord>> queued() => _query(
    where: 'status IN (?, ?)',
    whereArgs: [SmsStatus.queued.name, SmsStatus.sending.name],
    orderBy: 'timestamp ASC',
  );

  Future<int> countQueued() => _count('status IN (?, ?)', [
    SmsStatus.queued.name,
    SmsStatus.sending.name,
  ]);

  /// Queued records eligible for processing now, oldest first. Rows whose
  /// `next_attempt_at` is still in the future are skipped; `sending` rows are
  /// excluded ([reclaimStale] returns orphaned ones to `queued` first).
  Future<List<SmsRecord>> dueForDelivery(int now) => _query(
    where: 'status = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
    whereArgs: [SmsStatus.queued.name, now],
    orderBy: 'timestamp ASC',
  );

  Future<int> countFailed() => _count('status = ?', [SmsStatus.failure.name]);

  /// The soonest time any queued row wants to run (epoch ms), treating a null
  /// `next_attempt_at` as "due now" (0). Returns null when nothing is queued —
  /// used to decide whether/when to schedule a background catch-up.
  Future<int?> soonestQueuedAttempt() async {
    final rows = await _db.rawQuery(
      'SELECT MIN(COALESCE(next_attempt_at, 0)) AS soonest FROM $_table '
      'WHERE status = ?',
      [SmsStatus.queued.name],
    );
    return rows.first['soonest'] as int?;
  }

  /// Records that hit at least one real failure and are still retrying.
  Future<int> countRetrying() => _count('status IN (?, ?) AND attempts >= 1', [
    SmsStatus.queued.name,
    SmsStatus.sending.name,
  ]);

  /// Manual retry: returns all failed rows to `queued` for one more attempt.
  /// [attempts] is pre-set (usually maxAttempts - 1) so a single pass tries once.
  Future<void> requeueFailed(int now, {required int attempts}) async {
    await _db.update(
      _table,
      {
        'status': SmsStatus.queued.name,
        'attempts': attempts,
        'next_attempt_at': null,
        'updated_at': now,
      },
      where: 'status = ?',
      whereArgs: [SmsStatus.failure.name],
    );
  }

  /// Processed History (Transaction/Bill only), most recent first, paginated.
  /// [senderQuery] filters by sender or resolved contact name (case-insensitive).
  Future<List<SmsRecord>> history({
    int limit = kHistoryPageSize,
    int offset = 0,
    String? senderQuery,
  }) async {
    final (where, args) = _historyWhere(senderQuery);
    final rows = await _db.query(
      _table,
      where: where,
      whereArgs: args,
      orderBy: 'updated_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(SmsRecord.fromDbMap).toList();
  }

  /// Total History rows matching [senderQuery] (for pagination).
  Future<int> historyCount({String? senderQuery}) async {
    final (where, args) = _historyWhere(senderQuery);
    return _count(where, args);
  }

  (String, List<Object?>) _historyWhere(String? senderQuery) {
    final placeholders = kHistoryCategories.map((_) => '?').join(', ');
    final where = StringBuffer('status = ? AND category IN ($placeholders)');
    final args = <Object?>[SmsStatus.success.name, ...kHistoryCategories];
    final q = senderQuery?.trim();
    if (q != null && q.isNotEmpty) {
      where.write(' AND (sender LIKE ? OR contact_name LIKE ?)');
      args
        ..add('%$q%')
        ..add('%$q%');
    }
    return (where.toString(), args);
  }

  /// Bounds local storage: keeps only in-flight rows + the newest processed rows
  /// and deletes failures older than [failureCutoff] (epoch ms).
  Future<void> prune({
    int keepProcessed = 500,
    required int failureCutoff,
  }) async {
    await _db.rawDelete(
      'DELETE FROM $_table WHERE status = ? AND id NOT IN '
      '(SELECT id FROM $_table WHERE status = ? '
      ' ORDER BY updated_at DESC LIMIT ?)',
      [SmsStatus.success.name, SmsStatus.success.name, keepProcessed],
    );
    await _db.rawDelete(
      'DELETE FROM $_table WHERE status = ? AND updated_at < ?',
      [SmsStatus.failure.name, failureCutoff],
    );
  }

  Future<void> updateStatus(
    int id,
    SmsStatus status, {
    int? attempts,
    String? lastError,
    required int updatedAt,
    int? nextAttemptAt,
    String? category,
    int? processedAt,
  }) async {
    await _db.update(
      _table,
      {
        'status': status.name,
        'attempts': ?attempts,
        // Null-aware: omit so an in-flight retry keeps its prior error.
        'last_error': ?lastError,
        'updated_at': updatedAt,
        // NOT null-aware: always written so a scheduled retry can be cleared
        // (success / terminal failure pass null) or set (requeue passes a time).
        'next_attempt_at': nextAttemptAt,
        // Null-aware: only set on a terminal processed result.
        'category': ?category,
        'processed_at': ?processedAt,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atomically claims a queued row for processing (queued -> sending).
  /// Returns true only if this caller won the claim (multi-isolate safety).
  Future<bool> claim(int id, int updatedAt) async {
    final count = await _db.update(
      _table,
      {'status': SmsStatus.sending.name, 'updated_at': updatedAt},
      where: 'id = ? AND status = ?',
      whereArgs: [id, SmsStatus.queued.name],
    );
    return count == 1;
  }

  /// Requeues rows stuck in `sending` (orphaned by a killed isolate) whose last
  /// update predates [olderThan] (epoch ms).
  Future<void> reclaimStale(int olderThan) async {
    await _db.update(
      _table,
      {'status': SmsStatus.queued.name},
      where: 'status = ? AND updated_at < ?',
      whereArgs: [SmsStatus.sending.name, olderThan],
    );
  }

  Future<int> _count(String where, List<Object?> args) async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS c FROM $_table WHERE $where',
      args,
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  Future<List<SmsRecord>> _query({
    required String where,
    required List<Object?> whereArgs,
    required String orderBy,
    int? limit,
  }) async {
    final rows = await _db.query(
      _table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
    );
    return rows.map(SmsRecord.fromDbMap).toList();
  }
}
