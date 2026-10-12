import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/data/heartbeat_repository.dart';
import 'package:pawlet/services/heartbeat.dart';
import 'package:pawlet/services/heartbeat_reporter.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final now = DateTime.utc(2026, 10, 13, 12).millisecondsSinceEpoch;
  late Database db;
  late HeartbeatRepository repo;
  late int posts;

  setUp(() async {
    db = await openTestDb();
    repo = HeartbeatRepository(db);
    posts = 0;
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  Heartbeat heartbeat({int? version = 28}) => Heartbeat(
    repository: repo,
    reporter: HeartbeatReporter(
      apiBase: 'https://api.test',
      repository: repo,
      installId: () async => 'ab' * 32,
      isAllowed: () async => true,
      clock: () => now,
      client: MockClient((_) async {
        posts++;
        return http.Response('', 204);
      }),
    ),
    appVersionCode: () async => version,
    clock: () => now,
  );

  test('markOpened records opened and alive, then uploads', () async {
    await heartbeat().markOpened();
    final row = (await db.query('heartbeat_days')).single;
    expect([row['opened'], row['alive']], [1, 1]);
    expect(posts, 1);
  });

  test('markAlive records alive only', () async {
    await heartbeat().markAlive();
    final row = (await db.query('heartbeat_days')).single;
    expect([row['opened'], row['alive']], [0, 1]);
  });

  test('an unknown versionCode records nothing', () async {
    await heartbeat(version: null).markOpened();
    expect(await db.query('heartbeat_days'), isEmpty);
    expect(posts, 0);
  });

  test('never throws', () async {
    final h = heartbeat();
    await db.close();
    await h.markOpened();
  });

  group('syncHeartbeatMode', () {
    late int scheduled;
    late int cancelled;

    setUp(() {
      scheduled = 0;
      cancelled = 0;
    });

    Future<void> sync(LlmMode mode, {bool apiBase = true}) => syncHeartbeatMode(
      mode: mode,
      repository: repo,
      apiBaseConfigured: apiBase,
      schedule: () async => scheduled++,
      cancel: () async => cancelled++,
    );

    test('proxy and BYOK schedule the daily task', () async {
      await sync(LlmMode.proxy);
      await sync(LlmMode.byok);
      expect([scheduled, cancelled], [2, 0]);
    });

    test('no-LLM cancels the task and deletes the log', () async {
      await repo.mark(opened: true, nowMs: now, appVersionCode: 28);
      await sync(LlmMode.none);
      expect([scheduled, cancelled], [0, 1]);
      expect(await db.query('heartbeat_days'), isEmpty);
    });

    test('a build without a server never schedules', () async {
      await sync(LlmMode.byok, apiBase: false);
      expect([scheduled, cancelled], [0, 1]);
    });

    test('cancel throws but log still emptied', () async {
      await repo.mark(opened: true, nowMs: now, appVersionCode: 28);
      await syncHeartbeatMode(
        mode: LlmMode.none,
        repository: repo,
        apiBaseConfigured: true,
        schedule: () async {},
        cancel: () async => throw Exception('cancel failed'),
      );
      expect(await db.query('heartbeat_days'), isEmpty);
    });

    test('never throws', () async {
      await syncHeartbeatMode(
        mode: LlmMode.proxy,
        repository: repo,
        apiBaseConfigured: true,
        schedule: () async => throw Exception('no plugin'),
        cancel: () async {},
      );
    });
  });
}
