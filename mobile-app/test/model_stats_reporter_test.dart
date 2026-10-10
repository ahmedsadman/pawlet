import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/data/model_stats_repository.dart';
import 'package:pawlet/models/sms_record.dart';
import 'package:pawlet/services/auth/attestation_service.dart';
import 'package:pawlet/services/model_stats_reporter.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/db_test_helpers.dart';

class _FakeAttestation implements AttestationService {
  int tokens = 0;
  int forced = 0;
  bool rejected = false;
  AttestationException? error;

  @override
  String get apiBase => 'https://api.test';

  @override
  Future<String> token({bool forceRefresh = false}) async {
    tokens++;
    if (error != null) throw error!;
    if (forceRefresh) forced++;
    return 'jwt${forced + 1}';
  }

  @override
  Future<void> warmUp() async {}

  @override
  Future<void> reportRejected() async => rejected = true;

  @override
  void close() {}
}

http.Response _status(int code, [String body = '']) =>
    http.Response(body, code);

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  /// 2026-10-10 12:00 UTC.
  final start = DateTime.utc(2026, 10, 10, 12).millisecondsSinceEpoch;
  const hour = Duration.millisecondsPerHour;
  const minute = Duration.millisecondsPerMinute;

  late Database db;
  late ModelStatsRepository repo;
  late _FakeAttestation attestation;
  late List<http.Request> requests;
  late List<Object> script; // http.Response or an Exception to throw
  Future<void> Function()? onRequest;
  late int now;
  late Future<bool> Function() isProxy;
  var seq = 0;

  setUp(() async {
    db = await openTestDb();
    repo = ModelStatsRepository(db);
    attestation = _FakeAttestation();
    requests = [];
    script = [];
    onRequest = null;
    now = start;
    seq = 0;
    isProxy = () async => true;
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  ModelStatsReporter reporter() => ModelStatsReporter(
    apiBase: 'https://api.test',
    repository: repo,
    attestation: attestation,
    isProxy: () => isProxy(),
    clock: () => now,
    client: MockClient((req) async {
      requests.add(req);
      await onRequest?.call();
      final next = script.removeAt(0);
      if (next is Exception) throw next;
      return next as http.Response;
    }),
  );

  /// Counts one live message's verdict at the current clock.
  Future<void> countVerdict(LocalVerdict v, {int version = 21}) async {
    final id = await insertSms(
      db,
      sender: 'CHK',
      content: 'msg ${seq++}',
      ts: now,
      status: 'processing',
    );
    await repo.recordVerdict(id, v, nowMs: now, appVersionCode: version);
  }

  Future<int> seed(String day, {int version = 21}) => db.insert('model_stats', {
    'day': day,
    'app_version_code': version,
    'accepted': 1,
    'updated_at': 0,
  });

  Future<List<ModelStatsRow>> pending() =>
      repo.unreported(minDay: oldestKeptDay(now), limit: 100);

  List<Map<String, dynamic>> sentDays(http.Request r) =>
      ((jsonDecode(r.body) as Map<String, dynamic>)['days'] as List)
          .cast<Map<String, dynamic>>();

  test('posts the unreported days with the session token', () async {
    await countVerdict(LocalVerdict.accepted);
    await countVerdict(LocalVerdict.declined);
    await countVerdict(LocalVerdict.unavailable, version: 22);
    script = [_status(204)];

    await reporter().maybeFlush();

    final req = requests.single;
    expect(req.method, 'POST');
    expect(req.url.toString(), 'https://api.test/v1/model-stats');
    expect(req.headers['Authorization'], 'Bearer jwt1');
    expect(req.headers['Content-Type'], startsWith('application/json'));
    expect(jsonDecode(req.body), {
      'days': [
        {
          'day': '2026-10-10',
          'appVersionCode': 21,
          'accepted': 1,
          'declined': 1,
          'unavailable': 0,
        },
        {
          'day': '2026-10-10',
          'appVersionCode': 22,
          'accepted': 0,
          'declined': 0,
          'unavailable': 1,
        },
      ],
    });
  });

  test('a 2xx stamps the rows and starts the throttle', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(204)];

    await reporter().maybeFlush();

    expect(await pending(), isEmpty);
    expect(await repo.flushedAt(), start);
  });

  test('waits six hours after an acknowledged flush', () async {
    final r = reporter();
    await countVerdict(LocalVerdict.accepted);
    script = [_status(204), _status(204)];
    await r.maybeFlush();

    now = start + hour;
    await countVerdict(LocalVerdict.accepted);
    now = start + 6 * hour - 1;
    await r.maybeFlush();
    expect(requests, hasLength(1));

    now = start + 6 * hour;
    await r.maybeFlush();
    expect(requests, hasLength(2));
    expect(sentDays(requests.last).single['accepted'], 2);
  });

  test('honours a flush another isolate recorded', () async {
    await repo.setFlushedAt(start - hour);
    await countVerdict(LocalVerdict.accepted);

    await reporter().maybeFlush();

    expect(requests, isEmpty);
  });

  test('sends nothing, and asks for no token, when nothing changed', () async {
    await reporter().maybeFlush();

    expect(requests, isEmpty);
    expect(attestation.tokens, 0);
    expect(await repo.flushedAt(), isNull);
  });

  test('a 401 re-attests once and resends', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(401), _status(204)];

    await reporter().maybeFlush();

    expect(requests.map((r) => r.headers['Authorization']), [
      'Bearer jwt1',
      'Bearer jwt2',
    ]);
    expect(attestation.forced, 1);
    expect(await pending(), isEmpty);
    expect(await repo.flushedAt(), start);
  });

  test('a second 401 gives up for now', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(401), _status(401)];

    await reporter().maybeFlush();

    expect(requests, hasLength(2));
    expect(await pending(), hasLength(1));
    expect(await repo.flushedAt(), isNull);
  });

  test('a 403 is not retried and stamps nothing', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(403, '{"error":"banned"}')];

    await reporter().maybeFlush();

    expect(requests, hasLength(1));
    expect(await pending(), hasLength(1));
    expect(await repo.flushedAt(), isNull);
    // The session path owns ban handling; the reporter does not report it.
    expect(attestation.rejected, isFalse);
  });

  test('a 400 stamps the rows so a bad payload cannot loop', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(400, '{"error":"bad_request"}')];

    await reporter().maybeFlush();

    expect(requests, hasLength(1));
    expect(await pending(), isEmpty);
    expect(await repo.flushedAt(), isNull);
  });

  for (final code in const [404, 408, 429, 500, 503]) {
    test('HTTP $code leaves the rows for a later trigger', () async {
      await countVerdict(LocalVerdict.accepted);
      script = [_status(code)];

      await reporter().maybeFlush();

      expect(await pending(), hasLength(1));
      expect(await repo.flushedAt(), isNull);
    });
  }

  test('a network error leaves the rows for a later trigger', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [http.ClientException('offline')];

    await expectLater(reporter().maybeFlush(), completes);

    expect(await pending(), hasLength(1));
    expect(await repo.flushedAt(), isNull);
  });

  test('no session means no request', () async {
    await countVerdict(LocalVerdict.accepted);
    attestation.error = const AttestationException(
      'no Play Integrity channel',
      ineligible: false,
      needsForeground: true,
    );

    await reporter().maybeFlush();

    expect(requests, isEmpty);
    expect(await pending(), hasLength(1));
  });

  test('an increment that lands mid-flush goes out next time', () async {
    await countVerdict(LocalVerdict.accepted);
    script = [_status(204), _status(204)];
    onRequest = () async {
      onRequest = null;
      await countVerdict(LocalVerdict.declined);
    };
    final r = reporter();

    await r.maybeFlush();
    expect(sentDays(requests.single).single['declined'], 0);
    expect((await pending()).single.declined, 1);

    now = start + 6 * hour;
    await r.maybeFlush();
    expect(sentDays(requests.last).single['declined'], 1);
    expect(await pending(), isEmpty);
  });

  test('drops days past the 29-day window on each attempt', () async {
    await seed('2026-09-10');
    await seed('2026-09-11');
    script = [_status(204)];

    await reporter().maybeFlush();

    expect(sentDays(requests.single).map((d) => d['day']), ['2026-09-11']);
    final kept = await db.query('model_stats');
    expect(kept.map((r) => r['day']), ['2026-09-11']);
  });

  test('sends at most 31 rows, keeping the newest', () async {
    for (var i = 0; i < 20; i++) {
      final day = utcDay(
        DateTime.utc(2026, 9, 21).add(Duration(days: i)).millisecondsSinceEpoch,
      );
      await seed(day, version: 21);
      await seed(day, version: 22);
    }
    script = [_status(204)];

    await reporter().maybeFlush();

    final days = sentDays(requests.single);
    expect(days, hasLength(31));
    expect(days.first, containsPair('day', '2026-09-25'));
    expect(days.first, containsPair('appVersionCode', 22));
    expect(days.last, containsPair('day', '2026-10-10'));
    // The nine oldest rows wait for a later flush.
    expect(await pending(), hasLength(9));
  });

  test('one flush at a time per isolate', () async {
    await countVerdict(LocalVerdict.accepted);
    final gate = Completer<void>();
    onRequest = () => gate.future;
    script = [_status(204), _status(204)];
    final r = reporter();

    final a = r.maybeFlush();
    final b = r.maybeFlush();
    gate.complete();
    await Future.wait([a, b]);

    expect(requests, hasLength(1));
  });

  test('flushes normally while the install is still in proxy mode', () async {
    var checks = 0;
    isProxy = () async {
      checks++;
      return true;
    };
    await countVerdict(LocalVerdict.accepted);
    script = [_status(204)];

    await reporter().maybeFlush();

    expect(checks, 1);
    expect(requests, hasLength(1));
    expect(await pending(), isEmpty);
  });

  test('sends nothing once the install has left proxy mode', () async {
    isProxy = () async => false;
    await countVerdict(LocalVerdict.accepted);

    await reporter().maybeFlush();

    expect(attestation.tokens, 0);
    expect(requests, isEmpty);
    expect(await pending(), hasLength(1));
    expect(await repo.flushedAt(), isNull);
  });

  test('a failing mode check counts as not proxy', () async {
    isProxy = () async => throw StateError('prefs unavailable');
    await countVerdict(LocalVerdict.accepted);

    await expectLater(reporter().maybeFlush(), completes);

    expect(attestation.tokens, 0);
    expect(requests, isEmpty);
    expect(await repo.flushedAt(), isNull);
  });

  test('never throws, even with the database gone', () async {
    await db.close();

    await expectLater(reporter().maybeFlush(), completes);
  });

  group('backoff', () {
    Future<void> setMeta(String key, int value) => db.insert('app_meta', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    /// Runs one flush that the server answers with [answer] and returns how
    /// far past the clock the next attempt was put off, in ms.
    Future<int?> failOnce(Object answer) async {
      await countVerdict(LocalVerdict.accepted);
      script = [answer];
      await reporter().maybeFlush();
      final at = await repo.retryAt();
      return at == null ? null : at - now;
    }

    http.Response tooMany(String? retryAfter) =>
        http.Response('', 429, headers: {'retry-after': ?retryAfter});

    for (final code in const [500, 502, 503, 408]) {
      test('HTTP $code backs off 15 minutes', () async {
        expect(await failOnce(_status(code)), 15 * minute);
        expect(await repo.failures(), 1);
        expect(await pending(), hasLength(1));
      });
    }

    test('a network error backs off 15 minutes', () async {
      expect(await failOnce(http.ClientException('offline')), 15 * minute);
      expect(await repo.failures(), 1);
    });

    test('a timeout backs off 15 minutes', () async {
      expect(await failOnce(TimeoutException('slow')), 15 * minute);
      expect(await repo.failures(), 1);
    });

    test('no session backs off 15 minutes without a request', () async {
      attestation.error = const AttestationException(
        'no Play Integrity channel',
        ineligible: false,
        needsForeground: true,
      );
      await countVerdict(LocalVerdict.accepted);

      await reporter().maybeFlush();

      expect(requests, isEmpty);
      expect(await repo.retryAt(), now + 15 * minute);
      expect(await repo.failures(), 1);
    });

    test('a 401 after the re-attest backs off 15 minutes', () async {
      await countVerdict(LocalVerdict.accepted);
      script = [_status(401), _status(401)];

      await reporter().maybeFlush();

      expect(requests, hasLength(2));
      expect(await repo.retryAt(), now + 15 * minute);
      expect(await repo.failures(), 1);
    });

    for (final code in const [403, 404]) {
      test('HTTP $code backs off six hours', () async {
        expect(await failOnce(_status(code)), 6 * hour);
        expect(await repo.failures(), 1);
      });
    }

    test('doubles from 15 minutes up to a six-hour cap', () async {
      final r = reporter();
      final gaps = <int>[];
      for (var i = 0; i < 7; i++) {
        await countVerdict(LocalVerdict.accepted);
        script = [_status(500)];
        await r.maybeFlush();
        final at = (await repo.retryAt())!;
        gaps.add(at - now);
        now = at;
      }

      expect(requests, hasLength(7));
      expect(gaps, [
        15 * minute,
        30 * minute,
        hour,
        2 * hour,
        4 * hour,
        6 * hour,
        6 * hour,
      ]);
      expect(await repo.failures(), 7);
    });

    group('429', () {
      test('honours Retry-After in seconds', () async {
        expect(await failOnce(tooMany('120')), 120 * 1000);
        expect(await repo.failures(), 1);
      });

      test('honours Retry-After as an HTTP date', () async {
        final at = DateTime.fromMillisecondsSinceEpoch(
          start + 40 * minute,
          isUtc: true,
        );
        expect(await failOnce(tooMany(HttpDate.format(at))), 40 * minute);
      });

      test('waits at least a minute', () async {
        expect(await failOnce(tooMany('5')), minute);
      });

      test('a Retry-After date in the past waits a minute', () async {
        final at = DateTime.fromMillisecondsSinceEpoch(
          start - hour,
          isUtc: true,
        );
        expect(await failOnce(tooMany(HttpDate.format(at))), minute);
      });

      test('waits at most six hours', () async {
        expect(await failOnce(tooMany('86400')), 6 * hour);
      });

      test('a huge Retry-After in seconds waits six hours', () async {
        expect(await failOnce(tooMany('9223372036854776')), 6 * hour);
      });

      test('a far Retry-After date waits six hours', () async {
        final at = DateTime.fromMillisecondsSinceEpoch(
          start + 30 * hour,
          isUtc: true,
        );
        expect(await failOnce(tooMany(HttpDate.format(at))), 6 * hour);
      });

      test('without Retry-After falls back to the doubling', () async {
        await setMeta(kModelStatsFailuresKey, 2);
        expect(await failOnce(tooMany(null)), hour);
        expect(await repo.failures(), 3);
      });

      test('an unparseable Retry-After falls back to the doubling', () async {
        expect(await failOnce(tooMany('soon')), 15 * minute);
        expect(await repo.failures(), 1);
      });
    });

    test('a 2xx resend after a 401 clears the backoff', () async {
      await setMeta(kModelStatsFailuresKey, 3);
      await setMeta(kModelStatsRetryAtKey, start - minute);
      await countVerdict(LocalVerdict.accepted);
      script = [_status(401), _status(204)];

      await reporter().maybeFlush();

      expect(requests, hasLength(2));
      expect(await repo.failures(), 0);
      expect(await repo.retryAt(), isNull);
    });

    test('leaving proxy mode leaves the backoff alone', () async {
      isProxy = () async => false;
      await setMeta(kModelStatsFailuresKey, 3);
      await setMeta(kModelStatsRetryAtKey, start - minute);
      await countVerdict(LocalVerdict.accepted);

      await reporter().maybeFlush();

      expect(requests, isEmpty);
      expect(await repo.failures(), 3);
      expect(await repo.retryAt(), start - minute);
    });

    test('an empty payload leaves the backoff alone', () async {
      await setMeta(kModelStatsFailuresKey, 3);
      await setMeta(kModelStatsRetryAtKey, start - minute);

      await reporter().maybeFlush();

      expect(attestation.tokens, 0);
      expect(requests, isEmpty);
      expect(await repo.failures(), 3);
      expect(await repo.retryAt(), start - minute);
    });

    test('a 2xx clears the backoff', () async {
      await setMeta(kModelStatsFailuresKey, 3);
      await setMeta(kModelStatsRetryAtKey, start - minute);
      expect(await failOnce(_status(204)), isNull);
      expect(await repo.failures(), 0);
      expect(await repo.flushedAt(), start);
    });

    test('a 400 clears the backoff', () async {
      await setMeta(kModelStatsFailuresKey, 3);
      await setMeta(kModelStatsRetryAtKey, start - minute);
      expect(await failOnce(_status(400)), isNull);
      expect(await repo.failures(), 0);
      expect(await pending(), isEmpty);
    });

    test('a backed-off flush touches nothing', () async {
      var checks = 0;
      isProxy = () async {
        checks++;
        return true;
      };
      await countVerdict(LocalVerdict.accepted);
      await seed('2026-09-01'); // outside the window: a flush would prune it
      await setMeta(kModelStatsRetryAtKey, start + minute);

      await reporter().maybeFlush();

      expect(checks, 0);
      expect(attestation.tokens, 0);
      expect(requests, isEmpty);
      expect(await db.query('model_stats'), hasLength(2));
    });

    test('flushes again once the backoff has passed', () async {
      final r = reporter();
      expect(await failOnce(_status(500)), 15 * minute);

      now = start + 15 * minute - 1;
      await r.maybeFlush();
      expect(requests, hasLength(1));

      now = start + 15 * minute;
      script = [_status(204)];
      await r.maybeFlush();
      expect(requests, hasLength(2));
      expect(await pending(), isEmpty);
      expect(await repo.retryAt(), isNull);
    });

    test('a six-hour backoff is honoured to the end', () async {
      await countVerdict(LocalVerdict.accepted);
      await setMeta(kModelStatsRetryAtKey, start + 6 * hour);

      await reporter().maybeFlush();

      expect(requests, isEmpty);
    });

    test('a retry time over six hours ahead is ignored', () async {
      await countVerdict(LocalVerdict.accepted);
      await setMeta(kModelStatsRetryAtKey, start + 6 * hour + 1);
      script = [_status(204)];

      await reporter().maybeFlush();

      expect(requests, hasLength(1));
      expect(await pending(), isEmpty);
    });

    test('the failure count is shared through app_meta', () async {
      expect(await failOnce(_status(500)), 15 * minute);

      // Another isolate's reporter, on the same database.
      final other = reporter();
      now = start + 15 * minute - 1;
      await other.maybeFlush();
      expect(requests, hasLength(1));

      now = start + 15 * minute;
      script = [_status(503)];
      await other.maybeFlush();
      expect(requests, hasLength(2));
      expect(await repo.failures(), 2);
      expect(await repo.retryAt(), now + 30 * minute);
    });
  });
}
