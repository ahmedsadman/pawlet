import 'dart:async';
import 'dart:convert';

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

  late Database db;
  late ModelStatsRepository repo;
  late _FakeAttestation attestation;
  late List<http.Request> requests;
  late List<Object> script; // http.Response or an Exception to throw
  Future<void> Function()? onRequest;
  late int now;
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
  });

  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  ModelStatsReporter reporter() => ModelStatsReporter(
    apiBase: 'https://api.test',
    repository: repo,
    attestation: attestation,
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

  test('a second 401 gives up until the next trigger', () async {
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
    test('HTTP $code leaves the rows for the next trigger', () async {
      await countVerdict(LocalVerdict.accepted);
      script = [_status(code), _status(204)];
      final r = reporter();

      await r.maybeFlush();
      expect(await pending(), hasLength(1));
      expect(await repo.flushedAt(), isNull);

      // Not throttled: the next trigger tries again straight away.
      await r.maybeFlush();
      expect(requests, hasLength(2));
      expect(await pending(), isEmpty);
    });
  }

  test('a network error leaves the rows for the next trigger', () async {
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

  test('drops days past the 30-day window on each attempt', () async {
    await seed('2026-09-09');
    await seed('2026-09-10');
    script = [_status(204)];

    await reporter().maybeFlush();

    expect(sentDays(requests.single).map((d) => d['day']), ['2026-09-10']);
    final kept = await db.query('model_stats');
    expect(kept.map((r) => r['day']), ['2026-09-10']);
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

  test('never throws, even with the database gone', () async {
    await db.close();

    await expectLater(reporter().maybeFlush(), completes);
  });
}
