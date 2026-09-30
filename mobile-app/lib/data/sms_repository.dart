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

/// `app_meta` key holding a monotonic counter bumped whenever the pipeline
/// commits a data change (in ANY isolate). The UI polls it to detect writes made
/// by background isolates it can't otherwise observe. See [SmsRepository.dataRevision].
const String kDataRevKey = 'data_rev';

/// Financial categories that appear in History (alongside failures).
const List<String> kHistoryCategories = ['transaction', 'bill'];

/// A transaction with no bank attached, paired with the text of its backing
/// SMS so the account can be re-resolved without a second query.
class UnlinkedTransaction {
  const UnlinkedTransaction({
    required this.transactionId,
    required this.sender,
    required this.content,
  });

  final int transactionId;
  final String sender;
  final String content;
}

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

  /// The stored record matching the dedup key `(sender, timestamp, content)`,
  /// or null. The bulk inbox import uses it after [insertIfNew] reports a
  /// duplicate, to decide whether the existing row still needs processing.
  Future<SmsRecord?> findByIdentity({
    required String sender,
    required int timestamp,
    required String content,
  }) async {
    final rows = await _db.query(
      _table,
      where: 'sender = ? AND timestamp = ? AND content = ?',
      whereArgs: [sender, timestamp, content],
      limit: 1,
    );
    return rows.isEmpty ? null : SmsRecord.fromDbMap(rows.first);
  }

  /// Transactions carrying no bank, with the sender and body of the SMS they
  /// came from so a caller can re-resolve the account. Manual entries (no
  /// backing message) are excluded — they have no sender to match on.
  Future<List<UnlinkedTransaction>> unlinkedTransactions() async {
    final rows = await _db.rawQuery('''
      SELECT t.id AS tx_id, s.sender AS sender, s.content AS content
      FROM ${AppDatabase.transactionsTable} t
      JOIN $_table s ON s.id = t.message_id
      WHERE t.bank_id IS NULL
    ''');
    return rows
        .map(
          (r) => UnlinkedTransaction(
            transactionId: r['tx_id'] as int,
            sender: r['sender'] as String,
            content: r['content'] as String,
          ),
        )
        .toList();
  }

  /// Attaches a transaction to a bank. Guarded on the row still being unlinked
  /// so a concurrent write from the live pipeline is never overwritten.
  Future<void> setTransactionBank(int transactionId, int bankId) async {
    await _db.update(
      AppDatabase.transactionsTable,
      {'bank_id': bankId},
      where: 'id = ? AND bank_id IS NULL',
      whereArgs: [transactionId],
    );
  }

  /// Writes the terminal state of a bulk-imported record, overwriting every
  /// outcome column.
  ///
  /// Distinct from [updateStatus], whose null-aware writes deliberately
  /// preserve prior values: the import may re-process a row an earlier pass
  /// left `ignored` (e.g. a card bill that had no matching card yet), so a
  /// stale `ignore_reason` has to be cleared when it now succeeds. The import
  /// never retries, so `attempts`/`last_error`/`next_attempt_at` are reset too.
  Future<void> markBulkProcessed(
    int id, {
    required SmsStatus status,
    required int now,
    String? category,
    IgnoreReason? ignoreReason,
  }) async {
    await _db.update(
      _table,
      {
        'status': status.name,
        'attempts': 0,
        'last_error': null,
        'updated_at': now,
        'next_attempt_at': null,
        'category': category,
        'processed_at': now,
        'ignore_reason': ignoreReason?.value,
        'failure_reason': null,
        'parse_source': ParseSource.local.value,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Queued + in-flight records, oldest first (drives the Queue section).
  Future<List<SmsRecord>> queued() => _query(
    where: 'status IN (?, ?, ?)',
    whereArgs: [
      SmsStatus.queued.name,
      SmsStatus.processing.name,
      SmsStatus.sending.name,
    ],
    orderBy: 'timestamp ASC',
  );

  /// One page of queued + in-flight records, oldest first (drives the Queue
  /// section's pagination). Pair with [countQueued] for the total.
  Future<List<SmsRecord>> queuedPage({
    int limit = kQueuePageSize,
    int offset = 0,
  }) => _query(
    where: 'status IN (?, ?, ?)',
    whereArgs: [
      SmsStatus.queued.name,
      SmsStatus.processing.name,
      SmsStatus.sending.name,
    ],
    orderBy: 'timestamp ASC',
    limit: limit,
    offset: offset,
  );

  Future<int> countQueued() => _count('status IN (?, ?, ?)', [
    SmsStatus.queued.name,
    SmsStatus.processing.name,
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

  /// The `updated_at` of the row holding the single global LLM slot, or null
  /// when the slot is free. Used to schedule a wake at the slot's stale-reclaim
  /// time instead of a ~0-delay poll while an LLM call is in flight.
  Future<int?> oldestSendingAt() async {
    final rows = await _db.rawQuery(
      'SELECT MIN(updated_at) AS oldest FROM $_table WHERE status = ?',
      [SmsStatus.sending.name],
    );
    return rows.first['oldest'] as int?;
  }

  /// The oldest `updated_at` among rows claimed for processing in either state
  /// (`processing` or `sending`), or null when none. Used to schedule a
  /// stale-reclaim wake so a claimed row whose holder died is not stranded when
  /// nothing else is queued to trigger a pass.
  Future<int?> oldestInFlightAt() async {
    final rows = await _db.rawQuery(
      'SELECT MIN(updated_at) AS oldest FROM $_table WHERE status IN (?, ?)',
      [SmsStatus.processing.name, SmsStatus.sending.name],
    );
    return rows.first['oldest'] as int?;
  }

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
  /// paginated. [query] is a multi-word substring filter over sender and content
  /// (each term must match one of them; terms are ANDed).
  Future<List<SmsRecord>> history({
    int limit = kHistoryPageSize,
    int offset = 0,
    String? query,
  }) async {
    final (where, args) = _historyWhere(query);
    // LEFT JOIN the backing transaction so a transaction row can surface its
    // subcategory (type) in History; `tx_type` is null for bills and failures.
    final rows = await _db.rawQuery(
      '''
      SELECT s.*, t.type AS tx_type
      FROM $_table s
      LEFT JOIN ${AppDatabase.transactionsTable} t ON t.message_id = s.id
      WHERE $where
      ORDER BY s.updated_at DESC
      LIMIT ? OFFSET ?
      ''',
      [...args, limit, offset],
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
          " AND (sender LIKE ? ESCAPE '\\' OR content LIKE ? ESCAPE '\\')",
        );
        args
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

  /// The current data-change token (0 when never bumped). A single primary-key
  /// lookup on `app_meta` — cheap enough to poll from the UI every couple of
  /// seconds to detect writes made by background isolates (WorkManager / the
  /// background-SMS handler) that can't signal the UI isolate directly.
  Future<int> dataRevision() async => await _metaGetInt(kDataRevKey) ?? 0;

  /// Atomically increments the data-change token. Called by the pipeline after a
  /// pass commits changes, from whichever isolate ran it; the `ON CONFLICT`
  /// upsert keeps concurrent increments from different isolates consistent.
  Future<void> bumpDataRevision() async {
    await _db.rawInsert(
      'INSERT INTO ${AppDatabase.metaTable} (key, value) VALUES (?, 1) '
      'ON CONFLICT(key) DO UPDATE SET value = value + 1',
      [kDataRevKey],
    );
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
    ParseSource? parseSource,
    bool? needsLlm,
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
        // Null-aware: only stamped on a terminal processed result.
        'parse_source': ?parseSource?.value,
        // Only the Layer-3 deferral sets it, and it is never cleared, so every
        // other writer must leave the column alone.
        if (needsLlm != null) 'needs_llm': needsLlm ? 1 : 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Atomically takes a queued row for on-device work (queued -> processing).
  /// Returns true only if this caller won it.
  ///
  /// Per-row mutual exclusion ONLY: unlike the LLM slot, any number of rows may
  /// be `processing` at once across isolates. Local classification makes no
  /// network call and hits no rate limit, so serializing it would only make an
  /// in-flight LLM call (up to two minutes) stall messages the on-device model
  /// could have answered immediately. Because sqflite shares one native
  /// connection process-wide, concurrent claims on the SAME row serialize, so
  /// two callers can never both win. Orphaned rows (a killed holder) are freed
  /// by [reclaimStale].
  Future<bool> claimLocal(int id, int updatedAt) async {
    final count = await _db.update(
      _table,
      {'status': SmsStatus.processing.name, 'updated_at': updatedAt},
      where: 'id = ? AND status = ?',
      whereArgs: [id, SmsStatus.queued.name],
    );
    return count == 1;
  }

  /// Promotes a row this caller already holds (`processing`) into the single
  /// global LLM slot (`sending`). Returns false when another row is already in
  /// the slot, in which case the caller must release its row back to the queue.
  ///
  /// This is what caps LLM concurrency at one call process-wide (main,
  /// background-SMS and WorkManager isolates included) — the per-isolate
  /// `_running` guard cannot serialize across isolates. A row abandoned in the
  /// slot by a killed holder is freed by [reclaimStale]; the safety of that
  /// depends on OpenRouterProvider.timeout staying below
  /// ProcessingService.staleAfter (guarded by a test).
  Future<bool> acquireLlmSlot(int id, int updatedAt) async {
    final count = await _db.update(
      _table,
      {'status': SmsStatus.sending.name, 'updated_at': updatedAt},
      where:
          'id = ? AND status = ? '
          'AND NOT EXISTS (SELECT 1 FROM $_table WHERE status = ?)',
      whereArgs: [id, SmsStatus.processing.name, SmsStatus.sending.name],
    );
    return count == 1;
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

  /// Requeues rows stuck mid-processing (orphaned by a killed isolate) whose
  /// last update predates [olderThan] (epoch ms). Covers both in-flight states:
  /// `processing` (died during on-device work) and `sending` (died holding the
  /// LLM slot).
  Future<void> reclaimStale(int olderThan) async {
    await _db.update(
      _table,
      {'status': SmsStatus.queued.name},
      where: 'status IN (?, ?) AND updated_at < ?',
      whereArgs: [SmsStatus.processing.name, SmsStatus.sending.name, olderThan],
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
