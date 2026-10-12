import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/data/heartbeat_repository.dart';
import 'package:pawlet/services/heartbeat_reporter.dart';
import 'package:pawlet/services/upload_backoff.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 2026-10-13 12:00 UTC.
  final start = DateTime.utc(2026, 10, 13, 12).millisecondsSinceEpoch;
  const minute = Duration.millisecondsPerMinute;
  final installId = 'ab' * 32;

  late Database db;
  late HeartbeatRepository repo;
  late List<http.Request> requests;
  late List<Object> script; // http.Response or an Exception to throw
  late int now;
  late bool allowed;
  late bool idFails;

  setUp(() async {
    db = await openTestDb();
    repo = HeartbeatRepository(db);
    requests = [];
    script = [];
    now = start;
    allowed = true;
    idFails = false;
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  HeartbeatReporter reporter() => HeartbeatReporter(
    apiBase: 'https://api.test',
    repository: repo,
    installId: () async {
      if (idFails) throw Exception('keystore');
      return installId;
    },
    isAllowed: () async => allowed,
    clock: () => now,
    client: MockClient((req) async {
      requests.add(req);
      final next = script.isEmpty ? http.Response('', 204) : script.removeAt(0);
      if (next is Exception) throw next;
      return next as http.Response;
    }),
  );

  Future<void> mark({bool opened = true, int version = 28}) =>
      repo.mark(opened: opened, nowMs: now, appVersionCode: version);

  test('sends unreported days with the install ID and marks them', () async {
    await mark();
    await reporter().maybeFlush();

    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), 'https://api.test/v1/heartbeat');
    expect(requests.single.headers.containsKey('authorization'), isFalse);
    expect(jsonDecode(requests.single.body), {
      'installId': installId,
      'days': [
        {
          'day': '2026-10-13',
          'appVersionCode': 28,
          'opened': true,
          'alive': true,
        },
      ],
    });
    expect(await repo.unreported(minDay: '2026-09-14', limit: 31), isEmpty);
    expect(await repo.schedule.flushedAt(), start);
    expect(await repo.reportedVersion(), 28);
  });

  test('nothing to send means no request', () async {
    await reporter().maybeFlush();
    expect(requests, isEmpty);
  });

  test('throttles to one acknowledged flush an hour', () async {
    await mark(opened: false);
    await reporter().maybeFlush();
    now += 30 * minute;
    await mark(opened: true);
    await reporter().maybeFlush();
    expect(requests, hasLength(1));

    now += 31 * minute;
    await reporter().maybeFlush();
    expect(requests, hasLength(2));
  });

  test('a new versionCode skips the throttle', () async {
    await mark(version: 27);
    await reporter().maybeFlush();
    now += minute;
    await mark(version: 28);
    await reporter().maybeFlush();
    expect(requests, hasLength(2));
    expect(await repo.reportedVersion(), 28);
  });

  test('not allowed (no-LLM) sends nothing and keeps rows', () async {
    allowed = false;
    await mark();
    await reporter().maybeFlush();
    expect(requests, isEmpty);
    expect(
      await repo.unreported(minDay: '2026-09-14', limit: 31),
      hasLength(1),
    );
  });

  test('an unreadable install ID skips without backing off', () async {
    idFails = true;
    await mark();
    await reporter().maybeFlush();
    expect(requests, isEmpty);
    expect(await repo.schedule.retryAt(), isNull);
    expect(
      await repo.unreported(minDay: '2026-09-14', limit: 31),
      hasLength(1),
    );
  });

  test('400 marks the batch sent so it cannot loop', () async {
    script = [http.Response('{"error":"bad_request"}', 400)];
    await mark();
    await reporter().maybeFlush();
    expect(await repo.unreported(minDay: '2026-09-14', limit: 31), isEmpty);
    expect(await repo.schedule.retryAt(), isNull);
  });

  test('429 backs off by Retry-After', () async {
    script = [
      http.Response('', 429, headers: {'retry-after': '600'}),
    ];
    await mark();
    await reporter().maybeFlush();
    expect(await repo.schedule.retryAt(), start + 10 * minute);
    expect(
      await repo.unreported(minDay: '2026-09-14', limit: 31),
      hasLength(1),
    );

    now += 5 * minute;
    await reporter().maybeFlush();
    expect(requests, hasLength(1)); // still backing off
  });

  test('5xx and network errors double the backoff', () async {
    script = [http.Response('', 503), Exception('offline')];
    await mark();
    await reporter().maybeFlush();
    expect(
      await repo.schedule.retryAt(),
      start + kUploadBackoffBase.inMilliseconds,
    );

    now = (await repo.schedule.retryAt())!;
    await reporter().maybeFlush();
    expect(await repo.schedule.failures(), 2);
    expect(
      await repo.schedule.retryAt(),
      now + 2 * kUploadBackoffBase.inMilliseconds,
    );
  });

  test('a success clears the backoff', () async {
    script = [http.Response('', 503)];
    await mark();
    await reporter().maybeFlush();
    now = (await repo.schedule.retryAt())!;
    await reporter().maybeFlush();
    expect(await repo.schedule.failures(), 0);
    expect(await repo.schedule.retryAt(), isNull);
  });

  test('a retry time far ahead (clock moved back) holds nothing off', () async {
    await repo.schedule.recordFailure(
      (_) => start + 2 * kUploadBackoffCap.inMilliseconds,
    );
    await mark();
    await reporter().maybeFlush();
    expect(requests, hasLength(1));
  });

  test('never throws', () async {
    await db.close();
    await reporter().maybeFlush();
  });
}
