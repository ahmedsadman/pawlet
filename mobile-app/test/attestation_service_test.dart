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

  /// Nothing serves the channel, as in a background isolate.
  bool noChannel = false;
  int probes = 0;

  @override
  Future<void> ensureAvailable() async {
    probes++;
    if (noChannel) {
      throw const IntegrityException(
        PlayIntegrity.noActivity,
        permanent: false,
      );
    }
  }

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

  /// A session another isolate cached: this instance does not know when it
  /// was minted.
  Future<void> cacheForeignSession() =>
      SecureStore().writeSession('cached', _t0.add(const Duration(hours: 24)));

  test('forceRefresh re-mints a session that is still valid', () async {
    await cacheForeignSession();
    final s = service();
    expect(await s.token(), 'cached');
    expect(await s.token(forceRefresh: true), 'jwt1');
  });

  test(
    'forceRefresh forgets the rejected session even if minting fails',
    () async {
      await cacheForeignSession();
      final s = service();
      integrity.error = const IntegrityException('-3', permanent: false);
      await expectLater(s.token(forceRefresh: true), ineligible(false));
      expect(await SecureStore().readSession(), isNull);
    },
  );

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

    // The in-flight mint was released, so once the cooldown passes the next
    // call can succeed.
    integrity.hang = null;
    clock = clock.add(AttestationService.failureCooldown);
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

  group('a failed mint is remembered', () {
    Matcher needsForeground() => throwsA(
      isA<AttestationException>().having(
        (e) => e.needsForeground,
        'needsForeground',
        true,
      ),
    );

    test('no integrity channel fails before spending a challenge', () async {
      integrity.noChannel = true;
      await expectLater(service().token(), needsForeground());
      expect(server.challenges, 0);
      expect(integrity.hashes, isEmpty);
      expect(flagged, 0);
    });

    test('no integrity channel is never retried by this instance', () async {
      integrity.noChannel = true;
      final s = service();
      await expectLater(s.token(), needsForeground());
      clock = clock.add(const Duration(days: 2));
      await expectLater(s.token(), needsForeground());
      await expectLater(s.token(forceRefresh: true), needsForeground());
      await s.warmUp();
      expect(integrity.probes, 1);
      expect(server.challenges, 0);
    });

    test('a fresh instance tries again', () async {
      integrity.noChannel = true;
      await expectLater(service().token(), needsForeground());
      integrity.noChannel = false;
      expect(await service().token(), 'jwt1');
    });

    test('ineligible is never retried by this instance', () async {
      server.sessionStatus = 403;
      final s = service();
      await expectLater(s.token(), ineligible(true));
      server.sessionStatus = 200;
      clock = clock.add(const Duration(days: 2));
      await expectLater(s.token(), ineligible(true));
      await expectLater(s.token(forceRefresh: true), ineligible(true));
      await s.warmUp();
      expect(server.challenges, 1);
      expect(flagged, 1);
    });

    test('a transient failure is re-thrown until the cooldown ends', () async {
      server.sessionStatus = 503;
      final s = service();
      await expectLater(s.token(), ineligible(false));
      server.sessionStatus = 200;

      clock = clock.add(
        AttestationService.failureCooldown - const Duration(seconds: 1),
      );
      await expectLater(s.token(), ineligible(false));
      await expectLater(s.token(forceRefresh: true), ineligible(false));
      expect(server.challenges, 1);

      clock = clock.add(const Duration(seconds: 1));
      expect(await s.token(), 'jwt2');
      expect(server.challenges, 2);
    });

    Matcher retryAfter(Duration d) => throwsA(
      isA<AttestationException>().having((e) => e.retryAfter, 'retryAfter', d),
    );

    test('a transient failure carries what is left of the cooldown', () async {
      server.sessionStatus = 503;
      final s = service();
      await expectLater(
        s.token(),
        retryAfter(AttestationService.failureCooldown),
      );
      clock = clock.add(const Duration(minutes: 1));
      await expectLater(
        s.token(),
        retryAfter(
          AttestationService.failureCooldown - const Duration(minutes: 1),
        ),
      );
    });

    test('a permanent failure carries no retry hint', () async {
      integrity.noChannel = true;
      final s = service();
      await expectLater(
        s.token(),
        throwsA(
          isA<AttestationException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            isNull,
          ),
        ),
      );
    });

    test(
      'a fresh session rejected again is not re-minted per message',
      () async {
        await cacheForeignSession();
        final s = service();
        // Row 1: the cached token gets a 401, so it is refreshed once.
        expect(await s.token(), 'cached');
        expect(await s.token(forceRefresh: true), 'jwt1');
        // Its fresh token gets a 401 too. Row 2 gets the same: another mint
        // would only repeat it.
        expect(await s.token(), 'jwt1');
        await expectLater(
          s.token(forceRefresh: true),
          retryAfter(AttestationService.failureCooldown),
        );
        expect(await s.token(), 'jwt1');
        clock = clock.add(const Duration(minutes: 1));
        await expectLater(
          s.token(forceRefresh: true),
          retryAfter(
            AttestationService.failureCooldown - const Duration(minutes: 1),
          ),
        );
        expect(server.sessions, 1);

        // Past the cooldown the server is given another chance.
        clock = clock.add(AttestationService.failureCooldown);
        expect(await s.token(forceRefresh: true), 'jwt2');
      },
    );

    test('warmUp tries again despite a held transient failure', () async {
      server.sessionStatus = 503;
      final s = service();
      await expectLater(s.token(), ineligible(false));
      server.sessionStatus = 200;

      await s.warmUp();
      expect(server.challenges, 2);
      // The success cleared the held failure.
      await SecureStore().deleteSession();
      expect(await s.token(), 'jwt3');
    });

    test('a cached session is still served while a failure is held', () async {
      await cacheForeignSession();
      final s = service();
      server.sessionStatus = 503;
      await expectLater(s.token(forceRefresh: true), ineligible(false));
      // Another isolate minted meanwhile and cached it in the keystore.
      await SecureStore().writeSession(
        'other',
        _t0.add(const Duration(hours: 24)),
      );
      expect(await s.token(), 'other');
    });
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
