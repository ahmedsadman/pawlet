import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/sms_repository.dart';
import 'package:meowni/state/messages_providers.dart';
import 'package:meowni/state/providers.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<ProviderContainer> containerWith(SmsRepository repo) async {
    final c = ProviderContainer(
      overrides: [smsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('queuedProvider paginates queued rows, oldest first', () async {
    final db = await openTestDb();
    for (var i = 0; i < 25; i++) {
      await insertSms(
        db,
        sender: 'S$i',
        content: 'c$i',
        ts: i,
        status: 'queued',
      );
    }
    final c = await containerWith(SmsRepository(db));
    // Keep the autoDispose provider alive across reads.
    c.listen(queuedProvider, (_, _) {});

    final page1 = await c.read(queuedProvider.future);
    expect(page1.total, 25);
    expect(page1.page, 1);
    expect(page1.totalPages, 2);
    expect(page1.records.length, 20);
    expect(page1.records.first.sender, 'S0');

    c.read(queuePageIndexProvider.notifier).setPage(2);
    final page2 = await c.read(queuedProvider.future);
    expect(page2.page, 2);
    expect(page2.records.length, 5);

    await db.close();
  });

  test('queuedProvider clamps an out-of-range page', () async {
    final db = await openTestDb();
    await insertSms(db, sender: 'A', ts: 1, status: 'queued');
    final c = await containerWith(SmsRepository(db));
    c.listen(queuedProvider, (_, _) {});

    c.read(queuePageIndexProvider.notifier).setPage(9);
    final page = await c.read(queuedProvider.future);
    expect(page.page, 1); // clamped to the only page
    expect(page.records.single.sender, 'A');

    await db.close();
  });
}
