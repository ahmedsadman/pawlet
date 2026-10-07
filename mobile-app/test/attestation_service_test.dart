import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pawlet/data/secure_store.dart';
import 'package:pawlet/services/auth/attestation_service.dart';
import 'package:pawlet/services/auth/play_integrity.dart';

class _FakeIntegrity extends PlayIntegrity {
  _FakeIntegrity() : super(cloudProjectNumber: '1');

  final hashes = <String>[];
  Object? error;

  /// When set, requests wait on it: a Play Services that never answers.
  Completer<String>? hang;

  @override
  Future<String> requestToken(String requestHash) async {
    hashes.add(requestHash);
    if (error != null) throw error!;
    if (hang != null) return hang!.future;
    return 'integrity-token';
  }
}

/// A keystore that reads fine but refuses to store the session.
class _UnwritableStore extends SecureStore {
  @override
  Future<void> writeSession(String token, DateTime expiresAt) async {
    throw Exception('keystore locked');
  }
}

/// A keystore whose session entries cannot be deleted.
class _UndeletableStore extends SecureStore {
  @override
  Future<void> deleteSession() async {
    throw Exception('keystore locked');
  }
}

final _t0 = DateTime.utc(2026, 10, 8, 12);

/// Fake Pawlet server: counts calls per endpoint.
class _Server {
  int challenges = 0;
  int sessions = 0;
  int sessionStatus = 200;
  Map<String, dynamic>? lastSessionBody;
  Completer<void>? holdSession;

  late final client = MockClient((req) async {
    if (req.url.path == '/v1/challenge') {
      challenges++;
      return http.Response(jsonEncode({'challenge': 'c$challenges'}), 200);
    }
    if (req.url.path == '/v1/session') {
      sessions++;
      lastSessionBody = jsonDecode(req.body) as Map<String, dynamic>;
      if (holdSession != null) await holdSession!.future;
      if (sessionStatus != 200) {
        return http.Response('{"error":"x"}', sessionStatus);
      }
      final expiresAt = _t0.add(const Duration(hours: 24));
      return http.Response(
        jsonEncode({
          'token': 'jwt$sessions',
          'expiresAt': expiresAt.millisecondsSinceEpoch ~/ 1000,
        }),
        200,
      );
    }
    return http.Response('', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Server server;
  late _FakeIntegrity integrity;
  late DateTime clock;
  late int flagged;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    server = _Server();
    integrity = _FakeIntegrity();
    clock = _t0;
    flagged = 0;
  });

  AttestationService service({
    http.Client? client,
    SecureStore? store,
    Future<void> Function()? onIneligible,
    Duration integrityTimeout = AttestationService.integrityTimeout,
  }) => AttestationService(
    apiBase: 'https://api.test',
    store: store ?? SecureStore(),
    integrity: integrity,
    onIneligible: onIneligible ?? () async => flagged++,
    client: client ?? server.client,
    now: () => clock,
    integrityTimeout: integrityTimeout,
  );

  Future<void> throwingFlag() async {
    flagged++;
    throw Exception('prefs unavailable');
  }

  Matcher ineligible(bool value) => throwsA(
    isA<AttestationException>().having(
      (e) => e.ineligible,
      'ineligible',
      value,
    ),
  );

  test('mints a session bound to the install and the challenge', () async {
    expect(await service().token(), 'jwt1');

    final installId = await SecureStore().installId();
    expect(
      integrity.hashes.single,
      sha256.convert(utf8.encode('$installId:c1')).toString(),
    );
    expect(server.lastSessionBody, {
      'installId': installId,
      'challenge': 'c1',
      'integrityToken': 'integrity-token',
    });
  });

  test('a session that cannot be cached is still returned', () async {
    expect(await service(store: _UnwritableStore()).token(), 'jwt1');
    expect(await SecureStore().readSession(), isNull);
  });

  test('a cached session is reused without network', () async {
    final s = service();
    await s.token();
    expect(await s.token(), 'jwt1');
    expect(server.challenges, 1);
  });

  test('the cache is shared through the keystore, as isolates need', () async {
    await service().token();
    expect(await service().token(), 'jwt1');
    expect(server.challenges, 1);
  });

  test('an expired session is re-minted', () async {
    await service().token();
    clock = _t0.add(const Duration(hours: 25));
    expect(await service().token(), 'jwt2');
  });

  test('forceRefresh re-mints a session that is still valid', () async {
    final s = service();
    await s.token();
    expect(await s.token(forceRefresh: true), 'jwt2');
  });

  test('concurrent callers share one mint', () async {
    server.holdSession = Completer<void>();
    final s = service();
    final first = s.token();
    final second = s.token();
    await pumpEventQueue();
    server.holdSession!.complete();
    expect(await first, await second);
    expect(server.challenges, 1);
  });

  test('a 403 marks the install ineligible', () async {
    server.sessionStatus = 403;
    await expectLater(service().token(), ineligible(true));
    expect(flagged, 1);
  });

  test('a 503 is retryable and does not flag', () async {
    server.sessionStatus = 503;
    await expectLater(service().token(), ineligible(false));
    expect(flagged, 0);
  });

  test('a network failure is retryable', () async {
    final down = MockClient((_) async => throw http.ClientException('down'));
    await expectLater(service(client: down).token(), ineligible(false));
    expect(flagged, 0);
  });

  test('Play Services missing flags without calling the server', () async {
    integrity.error = const IntegrityException('-6', permanent: true);
    await expectLater(service().token(), ineligible(true));
    expect(flagged, 1);
    expect(server.sessions, 0);
  });

  test('a transient Play Integrity error does not flag', () async {
    integrity.error = const IntegrityException('-3', permanent: false);
    await expectLater(service().token(), ineligible(false));
    expect(flagged, 0);
  });

  test('a hung Play Integrity times out as retryable', () async {
    integrity.hang = Completer<String>();
    final s = service(integrityTimeout: const Duration(milliseconds: 10));
    await expectLater(s.token(), ineligible(false));
    expect(flagged, 0);

    // The in-flight mint was released, so the next call can succeed.
    integrity.hang = null;
    expect(await s.token(), 'jwt1');
  });

  test('an unexpected Play Integrity error is retryable', () async {
    integrity.error = StateError('boom');
    await expectLater(service().token(), ineligible(false));
    expect(flagged, 0);
  });

  test('a throwing onIneligible still yields an ineligible error', () async {
    server.sessionStatus = 403;
    await expectLater(
      service(onIneligible: throwingFlag).token(),
      ineligible(true),
    );
    expect(flagged, 1);
  });

  group('warmUp', () {
    test('does nothing while plenty of time remains', () async {
      await service().token();
      clock = _t0.add(const Duration(hours: 1));
      await service().warmUp();
      expect(server.challenges, 1);
    });

    test('renews when under two hours remain', () async {
      await service().token();
      clock = _t0.add(const Duration(hours: 23));
      await service().warmUp();
      expect(server.challenges, 2);
    });

    test('never throws', () async {
      server.sessionStatus = 503;
      await service().warmUp();
      expect(server.sessions, 1);
    });

    test('never throws when onIneligible throws', () async {
      server.sessionStatus = 403;
      await service(onIneligible: throwingFlag).warmUp();
      expect(flagged, 1);
    });
  });

  test('reportRejected drops the session and flags the install', () async {
    final s = service();
    await s.token();
    await s.reportRejected();
    expect(flagged, 1);
    expect(await SecureStore().readSession(), isNull);
  });

  test('reportRejected survives a keystore that cannot delete', () async {
    await service(store: _UndeletableStore()).reportRejected();
    expect(flagged, 1);
  });

  test('reportRejected survives a throwing onIneligible', () async {
    await service(onIneligible: throwingFlag).reportRejected();
    expect(flagged, 1);
  });
}
