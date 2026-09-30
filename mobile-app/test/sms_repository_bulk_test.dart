import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late SmsRepository repo;

  setUp(() async {
    db = await openTestDb();
    repo = SmsRepository(db);
  });

  tearDown(() => db.close());

  Future<int> seed({
    String sender = 'CHK',
    String content = 'debit 50',
    int timestamp = 1000,
  }) async => (await repo.insertIfNew(
    SmsRecord(
      sender: sender,
      content: content,
      timestamp: timestamp,
      updatedAt: timestamp,
    ),
  ))!;

  test('findNearDuplicate matches a capture inside the window', () async {
    // Live path stored the carrier's whole-second stamp; the import arrives
    // with Android's receipt time, 876ms later. Same SMS.
    final id = await seed(timestamp: 1782209211000);
    final found = await repo.findNearDuplicate(
      sender: 'CHK',
      timestamp: 1782209211876,
      content: 'debit 50',
    );
    expect(found?.id, id);
  });

  test('findNearDuplicate matches when the import is EARLIER', () async {
    // The sign flips on ~26% of real pairs: the device clock can run behind
    // the carrier's, so the window has to be symmetric.
    final id = await seed(timestamp: 1782209211000);
    final found = await repo.findNearDuplicate(
      sender: 'CHK',
      timestamp: 1782209210300,
      content: 'debit 50',
    );
    expect(found?.id, id);
  });

  test('findNearDuplicate window is inclusive and symmetric', () async {
    const stored = 1782209211000;
    await seed(timestamp: stored);

    Future<int?> at(int ts) async => (await repo.findNearDuplicate(
      sender: 'CHK',
      timestamp: ts,
      content: 'debit 50',
    ))?.id;

    // The boundary is inclusive on both sides: a capture exactly
    // kSmsDedupWindow away is still the same message.
    expect(await at(stored + 15000), isNotNull);
    expect(await at(stored - 15000), isNotNull);
    expect(await at(stored + 15001), isNull);
    expect(await at(stored - 15001), isNull);
  });

  test('findNearDuplicate is null when sender or content differs', () async {
    await seed(timestamp: 1000);
    expect(
      await repo.findNearDuplicate(
        sender: 'OTHER',
        timestamp: 1000,
        content: 'debit 50',
      ),
      isNull,
    );
    expect(
      await repo.findNearDuplicate(
        sender: 'CHK',
        timestamp: 1000,
        content: 'debit 51',
      ),
      isNull,
    );
  });

  test(
    'findNearDuplicate returns the closest row when several match',
    () async {
      await seed(timestamp: 100000);
      final near = await seed(timestamp: 112000);
      final found = await repo.findNearDuplicate(
        sender: 'CHK',
        timestamp: 113000,
        content: 'debit 50',
      );
      expect(found?.id, near);
    },
  );

  test('markBulkProcessed writes a terminal success row', () async {
    final id = await seed();
    await repo.markBulkProcessed(
      id,
      status: SmsStatus.success,
      now: 2000,
      category: 'transaction',
    );

    final row = (await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [id],
    )).first;
    expect(row['status'], 'success');
    expect(row['category'], 'transaction');
    expect(row['parse_source'], 'local');
    expect(row['processed_at'], 2000);
    expect(row['updated_at'], 2000);
    expect(row['next_attempt_at'], isNull);
  });

  test('markBulkProcessed writes a terminal ignored row', () async {
    final id = await seed();
    await repo.markBulkProcessed(
      id,
      status: SmsStatus.ignored,
      now: 2000,
      ignoreReason: IgnoreReason.localLowConfidence,
    );

    final row = (await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [id],
    )).first;
    expect(row['status'], 'ignored');
    expect(row['ignore_reason'], 'local_low_confidence');
    expect(row['category'], isNull);
    // Nothing is left for the queue to pick back up.
    expect(row['next_attempt_at'], isNull);
  });

  test(
    'markBulkProcessed clears a stale ignore reason on re-processing',
    () async {
      final id = await seed();
      await repo.markBulkProcessed(
        id,
        status: SmsStatus.ignored,
        now: 2000,
        ignoreReason: IgnoreReason.noRecord,
      );
      expect(
        (await db.query(
          'sms_records',
          where: 'id = ?',
          whereArgs: [id],
        )).first['ignore_reason'],
        'no_record',
      );

      // A later import run, once the missing card exists, succeeds — the old
      // reason must not linger on a success row.
      await repo.markBulkProcessed(
        id,
        status: SmsStatus.success,
        now: 3000,
        category: 'bill',
      );
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], 'success');
      expect(row['ignore_reason'], isNull);
      expect(row['category'], 'bill');
    },
  );

  test(
    'markBulkProcessed resets retry bookkeeping from a failed row',
    () async {
      final id = await seed();
      await repo.updateStatus(
        id,
        SmsStatus.failure,
        attempts: 9,
        lastError: 'boom',
        failureReason: FailureReason.retryExhausted,
        updatedAt: 1500,
        nextAttemptAt: 9999,
      );

      await repo.markBulkProcessed(
        id,
        status: SmsStatus.success,
        now: 3000,
        category: 'transaction',
      );

      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['attempts'], 0);
      expect(row['last_error'], isNull);
      expect(row['failure_reason'], isNull);
      expect(row['next_attempt_at'], isNull);
    },
  );
}
