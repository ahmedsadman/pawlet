import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/sms_repository.dart';
import 'package:meowni/models/sms_record.dart';
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
    await repo.updateStatus(b, SmsStatus.queued, updatedAt: 5, nextAttemptAt: 10_000);

    final due = await repo.dueForDelivery(1000);
    expect(due.map((r) => r.id), [a]);
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

  test('counts failed and retrying', () async {
    final db = await openTestDb();
    final repo = SmsRepository(db);
    final a = (await repo.insertIfNew(_sms('A', ts: 1)))!;
    final b = (await repo.insertIfNew(_sms('B', ts: 2)))!;
    await repo.updateStatus(a, SmsStatus.failure, attempts: 10, updatedAt: 5);
    await repo.updateStatus(b, SmsStatus.queued, attempts: 3, updatedAt: 5);

    expect(await repo.countFailed(), 1);
    expect(await repo.countRetrying(), 1);

    await repo.requeueFailed(9, attempts: 9);
    expect(await repo.countFailed(), 0);
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
      final rows = await repo.history(senderQuery: 'brac');
      expect(rows.map((r) => r.sender), ['BRAC']);
      expect(await repo.historyCount(senderQuery: 'brac'), 1);
    });

    test('paginates', () async {
      final repo = await seed();
      final page1 = await repo.history(limit: 1, offset: 0);
      final page2 = await repo.history(limit: 1, offset: 1);
      expect(page1.single.sender, 'EBL');
      expect(page2.single.sender, 'BRAC');
    });
  });
}
