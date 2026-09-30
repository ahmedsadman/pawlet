import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/sms_repository.dart';
import 'package:pawlet/models/finance/transaction.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

SmsRecord _sms(String sender, {String content = 'msg', required int ts}) =>
    SmsRecord(sender: sender, content: content, timestamp: ts, updatedAt: ts);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('insertIfNew dedupes by sender+timestamp+content', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = await repo.insertIfNew(_sms('A', content: 'x', ts: 1));
    expect(id, isNotNull);
    expect(await repo.insertIfNew(_sms('A', content: 'x', ts: 1)), isNull);
    await db.close();
  });

  test('dueForDelivery skips rows scheduled in the future', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    // b backs off into the future.
    await repo.updateStatus(
      b,
      SmsStatus.queued,
      updatedAt: 5,
      nextAttemptAt: 10_000,
    );

    final due = await repo.dueForDelivery(1000);
    expect(due.map((r) => r.id), [a]);
    await db.close();
  });

  test('bumpDataRevision atomically increments the change token', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    // Absent token reads as 0.
    expect(await repo.dataRevision(), 0);
    await repo.bumpDataRevision();
    expect(await repo.dataRevision(), 1);
    await repo.bumpDataRevision();
    await repo.bumpDataRevision();
    expect(await repo.dataRevision(), 3);
    await db.close();
  });

  test('claim is atomic; reclaimStale returns orphaned sending rows', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

    expect(await repo.claim(id, 100), isTrue);
    expect(await repo.claim(id, 200), isFalse); // already sending

    await repo.reclaimStale(150); // updated_at (100) < 150 → back to queued
    expect(await repo.claim(id, 300), isTrue);
    await db.close();
  });

  test(
    'oldestSendingAt returns the oldest in-flight updated_at, or null',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
      expect(await repo.oldestSendingAt(), isNull);

      await repo.claim(a, 100); // queued -> sending, updated_at = 100
      expect(await repo.oldestSendingAt(), 100);

      await repo.updateStatus(a, SmsStatus.success, updatedAt: 200);
      expect(await repo.oldestSendingAt(), isNull);
      await db.close();
    },
  );

  test('claim enforces a single global in-flight row', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;

    // First claim wins the single slot.
    expect(await repo.claim(a, 100), isTrue);
    // A different queued row cannot be claimed while one is already sending.
    expect(await repo.claim(b, 110), isFalse);

    // Free the slot (A reaches a terminal state), then B can claim.
    await repo.updateStatus(a, SmsStatus.success, updatedAt: 120);
    expect(await repo.claim(b, 130), isTrue);
    await db.close();
  });

  test('dueForDelivery breaks timestamp ties by id ascending', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', content: 'a', ts: 5)))!;
    final b = (await repo.insertIfNew(_sms('B', content: 'b', ts: 5)))!;
    final due = await repo.dueForDelivery(1000);
    expect(due.map((r) => r.id).toList(), [a, b]);
    await db.close();
  });

  test('countFailed counts only terminal failures', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    await repo.updateStatus(a, SmsStatus.failure, attempts: 10, updatedAt: 5);
    await repo.updateStatus(b, SmsStatus.queued, attempts: 3, updatedAt: 5);

    expect(await repo.countFailed(), 1);
    await db.close();
  });

  test('requeueOne returns exactly the one failed row to the queue', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    await repo.updateStatus(a, SmsStatus.failure, attempts: 10, updatedAt: 5);
    await repo.updateStatus(b, SmsStatus.failure, attempts: 10, updatedAt: 5);

    await repo.requeueOne(a, 9, attempts: 9);

    expect(await repo.countFailed(), 1); // only B remains failed
    final rowA = (await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [a],
    )).first;
    expect(rowA['status'], SmsStatus.queued.name);
    expect(rowA['attempts'], 9);
    expect(rowA['next_attempt_at'], isNull);
    await db.close();
  });

  test('requeueOne ignores a row that is not currently failed', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    await repo.updateStatus(id, SmsStatus.queued, attempts: 3, updatedAt: 5);

    await repo.requeueOne(id, 9, attempts: 9);

    final row = (await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [id],
    )).first;
    expect(row['attempts'], 3); // untouched — was not a failure
    await db.close();
  });

  group('history', () {
    Future<SmsRepository> seed() async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      Future<void> add(String sender, String cat, int ts) async {
        final id = (await repo.insertIfNew(_sms(sender, ts: ts)))!;
        await repo.updateStatus(
          id,
          SmsStatus.success,
          updatedAt: ts,
          category: cat,
          processedAt: ts,
        );
      }

      await add('BRAC', 'transaction', 10);
      await add('EBL', 'bill', 20);
      await add('Daraz', 'ignored', 30); // must not appear in history
      return repo;
    }

    test('shows only Transaction/Bill rows, newest first', () async {
      final repo = await seed();
      final rows = await repo.history();
      expect(rows.map((r) => r.sender), ['EBL', 'BRAC']);
      expect(await repo.historyCount(), 2);
    });

    test('filters by sender query', () async {
      final repo = await seed();
      final rows = await repo.history(query: 'brac');
      expect(rows.map((r) => r.sender), ['BRAC']);
      expect(await repo.historyCount(query: 'brac'), 1);
    });

    test('surfaces the backing transaction type; null for bills', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);

      final txId = (await repo.insertIfNew(_sms('BRAC', ts: 10)))!;
      await repo.updateStatus(
        txId,
        SmsStatus.success,
        updatedAt: 10,
        category: 'transaction',
        processedAt: 10,
      );
      await insertTx(
        db,
        messageId: txId,
        amount: '50',
        type: 'income',
        date: DateTime(2026, 1, 1),
      );

      final billId = (await repo.insertIfNew(_sms('EBL', ts: 20)))!;
      await repo.updateStatus(
        billId,
        SmsStatus.success,
        updatedAt: 20,
        category: 'bill',
        processedAt: 20,
      );

      final rows = await repo.history();
      final tx = rows.firstWhere((r) => r.sender == 'BRAC');
      final bill = rows.firstWhere((r) => r.sender == 'EBL');
      expect(tx.transactionType, TxType.income);
      expect(bill.transactionType, isNull);
      await db.close();
    });

    test('paginates', () async {
      final repo = await seed();
      final page1 = await repo.history(limit: 1, offset: 0);
      final page2 = await repo.history(limit: 1, offset: 1);
      expect(page1.single.sender, 'EBL');
      expect(page2.single.sender, 'BRAC');
    });

    test('shows failures alongside financial rows, hides ignored', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      Future<void> add(
        String sender,
        SmsStatus status,
        int ts, {
        String? category,
      }) async {
        final id = (await repo.insertIfNew(_sms(sender, ts: ts)))!;
        await repo.updateStatus(
          id,
          status,
          updatedAt: ts,
          category: category,
          processedAt: ts,
        );
      }

      await add('BRAC', SmsStatus.success, 10, category: 'transaction');
      await add('BADKEY', SmsStatus.failure, 20);
      await add('Daraz', SmsStatus.ignored, 30); // never shown

      final rows = await repo.history();
      expect(rows.map((r) => r.sender), ['BADKEY', 'BRAC']);
      expect(await repo.historyCount(), 2);
      await db.close();
    });

    test('multi-word search ANDs terms across sender/content', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      Future<void> add(String sender, String content, int ts) async {
        final id = (await repo.insertIfNew(
          _sms(sender, content: content, ts: ts),
        ))!;
        await repo.updateStatus(
          id,
          SmsStatus.success,
          updatedAt: ts,
          category: 'transaction',
          processedAt: ts,
        );
      }

      await add('EBL', 'your payment is due', 10); // both terms
      await add('EBL', 'balance update', 20); // only 'ebl'
      await add('BRAC', 'payment received', 30); // only 'payment'

      final rows = await repo.history(query: 'ebl payment');
      expect(rows.map((r) => r.sender), ['EBL']);
      expect(await repo.historyCount(query: 'ebl payment'), 1);
      await db.close();
    });

    test('search treats LIKE wildcards literally (ESCAPE)', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      Future<void> add(String content, int ts) async {
        final id = (await repo.insertIfNew(
          _sms('CHK', content: content, ts: ts),
        ))!;
        await repo.updateStatus(
          id,
          SmsStatus.success,
          updatedAt: ts,
          category: 'transaction',
          processedAt: ts,
        );
      }

      await add('a_b literal', 10);
      await add('axb wildcard', 20);

      // '_' must not act as a single-char wildcard: only the literal row matches.
      final rows = await repo.history(query: 'a_b');
      expect(rows.map((r) => r.content), ['a_b literal']);
      await db.close();
    });
  });

  group('queuedPage', () {
    Future<SmsRepository> seedQueued(int n) async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      for (var i = 0; i < n; i++) {
        // ts ascending so "oldest first" ordering is deterministic.
        await repo.insertIfNew(_sms('S$i', content: 'c$i', ts: i));
      }
      return repo;
    }

    test('returns a page of queued rows, oldest first', () async {
      final repo = await seedQueued(25);
      final page1 = await repo.queuedPage(limit: 20, offset: 0);
      final page2 = await repo.queuedPage(limit: 20, offset: 20);
      expect(page1.length, 20);
      expect(page1.first.sender, 'S0'); // oldest first
      expect(page2.length, 5);
      expect(await repo.countQueued(), 25);
    });

    test('includes in-flight (sending) rows', () async {
      final repo = await seedQueued(1);
      final id = (await repo.queuedPage()).single.id!;
      await repo.claim(id, 1); // queued -> sending
      final page = await repo.queuedPage();
      expect(page.single.status, SmsStatus.sending);
      expect(await repo.countQueued(), 1);
    });
  });

  group('updateStatus reasons', () {
    test('writes ignore_reason on an ignored row', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('CHK', ts: 1)))!;
      await repo.updateStatus(
        id,
        SmsStatus.ignored,
        updatedAt: 2,
        ignoreReason: IgnoreReason.gated,
        processedAt: 2,
      );
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['status'], 'ignored');
      expect(row['ignore_reason'], 'gated');
      expect(row['category'], isNull);
      await db.close();
    });

    test('writes failure_reason and last_error on a failed row', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('CHK', ts: 1)))!;
      await repo.updateStatus(
        id,
        SmsStatus.failure,
        updatedAt: 2,
        failureReason: FailureReason.llmError,
        lastError: 'boom',
      );
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).single;
      expect(row['status'], 'failure');
      expect(row['failure_reason'], 'llm_error');
      expect(row['last_error'], 'boom');
      await db.close();
    });
  });

  test('claimLocal is atomic; reclaimStale frees an orphan', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

    expect(await repo.claimLocal(id, 100), isTrue);
    expect(await repo.claimLocal(id, 200), isFalse); // already processing

    await repo.reclaimStale(150); // updated_at (100) < 150 → back to queued
    expect(await repo.claimLocal(id, 300), isTrue);
    await db.close();
  });

  test('claimLocal does NOT block on another row being in flight', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;

    expect(await repo.claimLocal(a, 100), isTrue);
    expect(await repo.acquireLlmSlot(a, 105), isTrue); // a holds the LLM slot
    // The whole point of the split: local work proceeds anyway.
    expect(await repo.claimLocal(b, 110), isTrue);
    await db.close();
  });

  test('acquireLlmSlot admits exactly one row process-wide', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    await repo.claimLocal(a, 100);
    await repo.claimLocal(b, 101);

    expect(await repo.acquireLlmSlot(a, 110), isTrue);
    expect(await repo.acquireLlmSlot(b, 111), isFalse); // slot held by a

    // a reaches a terminal state, freeing the slot.
    await repo.updateStatus(a, SmsStatus.success, updatedAt: 120);
    expect(await repo.acquireLlmSlot(b, 130), isTrue);
    await db.close();
  });

  test('acquireLlmSlot refuses a row this caller does not hold', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    // Still `queued` — never went through claimLocal.
    expect(await repo.acquireLlmSlot(id, 100), isFalse);
    await db.close();
  });

  test('reclaimStale frees orphaned processing rows too', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    await repo.claimLocal(id, 100); // died here — never reached the LLM

    await repo.reclaimStale(150);
    expect(await repo.claimLocal(id, 200), isTrue);
    await db.close();
  });

  test('oldestSendingAt ignores rows that are only processing', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    expect(await repo.oldestSendingAt(), isNull);

    await repo.claimLocal(id, 100);
    expect(await repo.oldestSendingAt(), isNull); // local work is not the slot

    await repo.acquireLlmSlot(id, 110);
    expect(await repo.oldestSendingAt(), 110);

    await repo.updateStatus(id, SmsStatus.success, updatedAt: 120);
    expect(await repo.oldestSendingAt(), isNull);
    await db.close();
  });

  test('oldestInFlightAt covers processing and sending', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    expect(await repo.oldestInFlightAt(), isNull);

    await repo.claimLocal(b, 300);
    expect(await repo.oldestInFlightAt(), 300);

    await repo.claimLocal(a, 100);
    await repo.acquireLlmSlot(a, 105);
    expect(await repo.oldestInFlightAt(), 105); // min(105, 300)
    await db.close();
  });

  test('countQueued and queuedPage include processing rows', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    await repo.claimLocal(id, 100);

    expect(await repo.countQueued(), 1);
    final page = await repo.queuedPage();
    expect(page.single.status, SmsStatus.processing);
    await db.close();
  });

  test(
    'updateStatus can set needs_llm without touching it otherwise',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
      await repo.claimLocal(id, 100);

      await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 110,
        nextAttemptAt: null,
        needsLlm: true,
      );
      expect((await repo.dueForDelivery(200)).single.needsLlm, isTrue);

      // A later write that says nothing about the flag must preserve it.
      await repo.updateStatus(id, SmsStatus.queued, updatedAt: 120);
      expect((await repo.dueForDelivery(200)).single.needsLlm, isTrue);
      await db.close();
    },
  );

  test(
    'updateStatus with matching heldSince applies and returns true',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
      await repo.claimLocal(id, 100);

      final applied = await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 110,
        heldSince: 100,
      );
      expect(applied, isTrue);
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.queued.name);
      expect(row['updated_at'], 110);
      await db.close();
    },
  );

  test(
    'updateStatus with stale heldSince does NOT apply and returns false',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

      // First holder claims at t=100.
      await repo.claimLocal(id, 100);
      // Row is reclaimed and a second holder claims at t=300.
      await repo.reclaimStale(200);
      await repo.claimLocal(id, 300);

      // First holder tries to write with its stale heldSince=100.
      final applied = await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 400,
        heldSince: 100,
      );
      expect(applied, isFalse);

      // Row is left as the new holder left it.
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.processing.name);
      expect(row['updated_at'], 300);
      await db.close();
    },
  );

  test(
    'updateStatus without heldSince still applies unconditionally',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
      await repo.claimLocal(id, 100);

      // No heldSince → unconditional write.
      final applied = await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 200,
      );
      expect(applied, isTrue);
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.queued.name);
      await db.close();
    },
  );

  test(
    'a stale holder cannot free the LLM slot out from under a live call',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

      // First holder claims local at t=100, then acquires the LLM slot at t=110.
      await repo.claimLocal(id, 100);
      await repo.acquireLlmSlot(id, 110);
      // First holder freezes. Row is reclaimed and a second holder claims and
      // acquires the slot again.
      await repo.reclaimStale(200);
      await repo.claimLocal(id, 300);
      await repo.acquireLlmSlot(id, 310);

      // Now the row is `sending` with updated_at=310. The frozen first holder
      // wakes and tries to write `queued` with its stale heldSince=110.
      final applied = await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 400,
        heldSince: 110,
      );
      expect(applied, isFalse);

      // Critical: the row is still `sending`, so the LLM slot is still held.
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.sending.name);
      expect(row['updated_at'], 310);
      await db.close();
    },
  );

  test(
    'releaseLocal returns the row to queued and preserves attempts',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

      // Set some retry state before claiming.
      await repo.updateStatus(
        id,
        SmsStatus.queued,
        updatedAt: 50,
        attempts: 2,
        nextAttemptAt: 60,
      );
      await repo.claimLocal(id, 100);

      // Release it back.
      final released = await repo.releaseLocal(id, 100);
      expect(released, isTrue);

      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.queued.name);
      expect(row['updated_at'], 100); // Not touched by releaseLocal.
      expect(row['attempts'], 2); // Preserved.
      expect(row['next_attempt_at'], 60); // Preserved.
      await db.close();
    },
  );

  test('releaseLocal can set needs_llm', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    await repo.claimLocal(id, 100);

    await repo.releaseLocal(id, 100, needsLlm: true);

    final row = (await db.query(
      'sms_records',
      where: 'id = ?',
      whereArgs: [id],
    )).first;
    expect(row['needs_llm'], 1);
    await db.close();
  });

  test(
    'releaseLocal with stale heldSince is a no-op returning false',
    () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final id = (await repo.insertIfNew(_sms('A', ts: 1)))!;

      // First holder claims at t=100.
      await repo.claimLocal(id, 100);
      // Reclaim and second holder claims at t=300.
      await repo.reclaimStale(200);
      await repo.claimLocal(id, 300);

      // First holder tries to release with stale heldSince=100.
      final released = await repo.releaseLocal(id, 100);
      expect(released, isFalse);

      // Row still held by the new holder.
      final row = (await db.query(
        'sms_records',
        where: 'id = ?',
        whereArgs: [id],
      )).first;
      expect(row['status'], SmsStatus.processing.name);
      expect(row['updated_at'], 300);
      await db.close();
    },
  );

  group('pruneIfDue', () {
    Future<int> addIgnored(
      SmsRepository repo,
      String sender,
      int updatedAt, {
      int ts = 1,
    }) async {
      final id = (await repo.insertIfNew(_sms(sender, ts: ts)))!;
      await repo.updateStatus(
        id,
        SmsStatus.ignored,
        updatedAt: updatedAt,
        ignoreReason: IgnoreReason.gated,
      );
      return id;
    }

    Future<int> countRows(Database db, String status) async {
      final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM sms_records WHERE status = ?',
        [status],
      );
      return rows.first['c'] as int;
    }

    test('deletes ignored rows older than the retention window', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final now = 100 * Duration.millisecondsPerDay;
      await addIgnored(repo, 'OLD', now - 8 * Duration.millisecondsPerDay);
      await addIgnored(repo, 'NEW', now - 6 * Duration.millisecondsPerDay);

      await repo.pruneIfDue(now: now);

      final rows = await repo.history(); // ignored never in history; query raw
      expect(rows, isEmpty);
      final remaining = await db.query('sms_records', orderBy: 'sender');
      expect(remaining.map((r) => r['sender']), ['NEW']);
      await db.close();
    });

    test('never deletes success rows, even beyond the old 500 cap', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final now = 100 * Duration.millisecondsPerDay;
      for (var i = 0; i < 600; i++) {
        final id = (await repo.insertIfNew(
          _sms('S$i', content: 'c$i', ts: i),
        ))!;
        await repo.updateStatus(
          id,
          SmsStatus.success,
          updatedAt: 1,
          category: 'transaction',
          processedAt: 1,
        );
      }
      await repo.pruneIfDue(now: now);
      expect(await countRows(db, 'success'), 600);
      await db.close();
    });

    test('never deletes failure rows', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final now = 100 * Duration.millisecondsPerDay;
      final id = (await repo.insertIfNew(_sms('BAD', ts: 1)))!;
      await repo.updateStatus(
        id,
        SmsStatus.failure,
        updatedAt: 1,
        failureReason: FailureReason.llmError,
      ); // very old
      await repo.pruneIfDue(now: now);
      expect(await countRows(db, 'failure'), 1);
      await db.close();
    });

    test('throttles: a second call within the min gap is a no-op', () async {
      final db = await openTestDb();
      final repo = SmsRepository(db);
      final now = 100 * Duration.millisecondsPerDay;
      // First call with nothing to prune stamps last_prune_at = now.
      await repo.pruneIfDue(now: now);
      // Now an aged ignored row appears.
      await addIgnored(repo, 'OLD', now - 8 * Duration.millisecondsPerDay);

      // Within 24h → throttled → row survives.
      await repo.pruneIfDue(now: now + Duration.millisecondsPerHour);
      expect(await countRows(db, 'ignored'), 1);

      // Past the gap → runs → row deleted.
      await repo.pruneIfDue(now: now + 25 * Duration.millisecondsPerHour);
      expect(await countRows(db, 'ignored'), 0);
      await db.close();
    });
  });
}
