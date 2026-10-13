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
  late int? installedAt;

  setUp(() async {
    db = await openTestDb();
    repo = HeartbeatRepository(db);
    requests = [];
    script = [];
    now = start;
    allowed = true;
    idFails = false;
    // Long enough ago that the first-upload delay is over.
    installedAt = start - 7 * Duration.millisecondsPerDay;
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
    installedAt: () async => installedAt,
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
    expect(
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
      isEmpty,
    );
    expect(await repo.schedule.flushedAt(), start);
    expect(await repo.reportedVersion(), 28);
  });

  group('first upload after install', () {
    const hour = Duration.millisecondsPerHour;

    test('waits 6 hours, keeping the days for later', () async {
      installedAt = start - 5 * hour;
      await mark();
      await reporter().maybeFlush();
      expect(requests, isEmpty);

      now = start + hour;
      await mark(opened: false);
      await reporter().maybeFlush();
      expect(requests, hasLength(1));
      expect((jsonDecode(requests.single.body) as Map)['days'], [
        {
          'day': '2026-10-13',
          'appVersionCode': 28,
          'opened': true,
          'alive': true,
        },
      ]);
    });

    test('an unknown install time does not delay', () async {
      installedAt = null;
      await mark();
      await reporter().maybeFlush();
      expect(requests, hasLength(1));
    });

    test(
      'an install time in the future (clock moved back) does not delay',
      () async {
        installedAt = start + hour;
        await mark();
        await reporter().maybeFlush();
        expect(requests, hasLength(1));
      },
    );

    test('a failing install-time read does not delay', () async {
      final r = HeartbeatReporter(
        apiBase: 'https://api.test',
        repository: repo,
        installId: () async => installId,
        isAllowed: () async => true,
        installedAt: () async => throw Exception('plugin'),
        clock: () => now,
        client: MockClient((req) async {
          requests.add(req);
          return http.Response('', 204);
        }),
      );
      await mark();
      await r.maybeFlush();
      expect(requests, hasLength(1));
    });
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
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
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
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
      hasLength(1),
    );
  });

  test('400 marks the batch sent so it cannot loop', () async {
    script = [http.Response('{"error":"bad_request"}', 400)];
    await mark();
    await reporter().maybeFlush();
    expect(
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
      isEmpty,
    );
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
      await repo.unreported(
        minDay: '2026-09-14',
        maxDay: '9999-12-31',
        limit: 31,
      ),
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

  test('a future-dated row is held back until valid', () async {
    const day = Duration.millisecondsPerDay;
    await mark();
    // A row 3 days ahead: invalid.
    await repo.mark(opened: true, nowMs: now + 3 * day, appVersionCode: 29);
    await reporter().maybeFlush();
    expect(requests, hasLength(1));
    expect(jsonDecode(requests.single.body)['days'], [
      {
        'day': '2026-10-13',
        'appVersionCode': 28,
        'opened': true,
        'alive': true,
      },
    ]);
  });

  test('two concurrent maybeFlush calls share one request', () async {
    await mark();
    final r = reporter();
    final a = r.maybeFlush();
    final b = r.maybeFlush();
    await Future.wait([a, b]);
    expect(requests, hasLength(1));
  });

  test('a flushedAt stamp in the future does not throttle', () async {
    await mark();
    await repo.schedule.setFlushedAt(start + 10 * minute);
    await reporter().maybeFlush();
    expect(requests, hasLength(1));
  });

  test('never throws', () async {
    await db.close();
    await reporter().maybeFlush();
  });
}
