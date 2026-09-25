import 'package:sqflite/sqflite.dart';

import '../models/sms_record.dart';
import 'database.dart';

/// Default page size for History.
const int kHistoryPageSize = 20;

/// Default page size for the Queue (mirrors History).
const int kQueuePageSize = 20;

/// How long `ignored` records are retained before [SmsRepository.pruneIfDue]
/// deletes them. Success and failure rows are permanent.
const Duration kIgnoredRetention = Duration(days: 7);

/// Minimum wall-clock gap between two real prunes (DB-backed throttle).
const Duration kPruneMinGap = Duration(hours: 24);

/// `app_meta` key holding the epoch-ms time of the last real prune.
const String kLastPruneAtKey = 'last_prune_at';

/// Financial categories that appear in History (alongside failures).
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

  /// One page of queued + in-flight records, oldest first (drives the Queue
  /// section's pagination). Pair with [countQueued] for the total.
  Future<List<SmsRecord>> queuedPage({
    int limit = kQueuePageSize,
    int offset = 0,
  }) => _query(
    where: 'status IN (?, ?)',
    whereArgs: [SmsStatus.queued.name, SmsStatus.sending.name],
    orderBy: 'timestamp ASC',
    limit: limit,
    offset: offset,
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
    // First-come-first-served, with id as a deterministic tiebreak for rows
    // sharing a timestamp.
    orderBy: 'timestamp ASC, id ASC',
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

  /// Manual single-message retry: returns one `failure` row to `queued`, due
  /// now. [attempts] is pre-set (usually maxAttempts - 1) so a single pass tries
  /// once more before failing again. Guarded on `status = failure` so a
  /// double-tap or a row already re-queued elsewhere is a safe no-op.
  Future<void> requeueOne(int id, int now, {required int attempts}) async {
    await _db.update(
      _table,
      {
        'status': SmsStatus.queued.name,
        'attempts': attempts,
        'next_attempt_at': null,
        'updated_at': now,
      },
      where: 'id = ? AND status = ?',
      whereArgs: [id, SmsStatus.failure.name],
    );
  }

  /// Processed History (financial rows + failures), most recent first,
  /// paginated. [query] is a multi-word substring filter over sender, contact
  /// name, and content (each term must match one of them; terms are ANDed).
  Future<List<SmsRecord>> history({
    int limit = kHistoryPageSize,
    int offset = 0,
    String? query,
  }) async {
    final (where, args) = _historyWhere(query);
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

  /// Total History rows matching [query] (for pagination).
  Future<int> historyCount({String? query}) async {
    final (where, args) = _historyWhere(query);
    return _count(where, args);
  }

  (String, List<Object?>) _historyWhere(String? query) {
    final placeholders = kHistoryCategories.map((_) => '?').join(', ');
    // Financial (success + transaction/bill) rows and failures are shown;
    // ignored rows never are.
    final where = StringBuffer(
      '((status = ? AND category IN ($placeholders)) OR status = ?)',
    );
    final args = <Object?>[
      SmsStatus.success.name,
      ...kHistoryCategories,
      SmsStatus.failure.name,
    ];
    final q = query?.trim();
    if (q != null && q.isNotEmpty) {
      for (final term in q.split(RegExp(r'\s+'))) {
        final like = '%${_escapeLike(term)}%';
        where.write(
          " AND (sender LIKE ? ESCAPE '\\' OR contact_name LIKE ? ESCAPE '\\' "
          "OR content LIKE ? ESCAPE '\\')",
        );
        args
          ..add(like)
          ..add(like)
          ..add(like);
      }
    }
    return (where.toString(), args);
  }

  /// Escapes LIKE wildcards so a user's `%`/`_` are matched literally (paired
  /// with `ESCAPE '\'`). Backslash is escaped first so it doesn't double-escape.
  String _escapeLike(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// Bounds local storage by deleting aged `ignored` rows, at most once per
  /// [minGap] (a DB-backed throttle so all triggers and both isolates share one
  /// budget). Success and failure rows are permanent. Deletes ignored rows whose
  /// `updated_at` predates `now - ignoredRetention`.
  Future<void> pruneIfDue({
    required int now,
    Duration minGap = kPruneMinGap,
    Duration ignoredRetention = kIgnoredRetention,
  }) async {
    final last = await _metaGetInt(kLastPruneAtKey);
    if (last != null && now - last < minGap.inMilliseconds) return;

    await _db.rawDelete(
      'DELETE FROM $_table WHERE status = ? AND updated_at < ?',
      [SmsStatus.ignored.name, now - ignoredRetention.inMilliseconds],
    );
    await _metaSetInt(kLastPruneAtKey, now);
  }

  Future<int?> _metaGetInt(String key) async {
    final rows = await _db.query(
      AppDatabase.metaTable,
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as int?;
  }

  Future<void> _metaSetInt(String key, int value) async {
    await _db.insert(AppDatabase.metaTable, {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    IgnoreReason? ignoreReason,
    FailureReason? failureReason,
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
        // Null-aware: only stamped on the matching terminal state.
        'ignore_reason': ?ignoreReason?.value,
        'failure_reason': ?failureReason?.value,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atomically claims a queued row for processing (queued -> sending), but only
  /// when no other row is already `sending`. This enforces a single global
  /// in-flight message across every isolate (main, background-SMS, WorkManager),
  /// so at most one LLM call runs at a time — the per-isolate `_running` guard
  /// alone can't serialize across isolates. Returns true only if this caller won
  /// the claim: the row was still queued AND the single slot was free. Because
  /// sqflite shares one native connection process-wide, concurrent claims from
  /// different isolates serialize, so two can never both win. Orphaned `sending`
  /// rows (a killed holder) are freed by [reclaimStale].
  Future<bool> claim(int id, int updatedAt) async {
    final count = await _db.update(
      _table,
      {'status': SmsStatus.sending.name, 'updated_at': updatedAt},
      where:
          'id = ? AND status = ? '
          'AND NOT EXISTS (SELECT 1 FROM $_table WHERE status = ?)',
      whereArgs: [id, SmsStatus.queued.name, SmsStatus.sending.name],
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
    int? offset,
  }) async {
    final rows = await _db.query(
      _table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    return rows.map(SmsRecord.fromDbMap).toList();
  }
}
