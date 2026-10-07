// Private fields fed by named constructor params are assigned explicitly, as
// elsewhere in the app.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../data/secure_store.dart';
import 'play_integrity.dart';

/// Attestation did not produce a session. [ineligible] means the server or
/// Play said this install cannot attest (the caller has already been told via
/// `onIneligible`); otherwise the failure is worth retrying.
///
/// [needsForeground] means this isolate has no Play Integrity channel (a
/// background isolate), so only the foreground app can mint a session.
///
/// [retryAfter] is how long this instance will keep re-throwing the failure
/// (see [AttestationService.failureCooldown]); null when it never will retry.
class AttestationException implements Exception {
  const AttestationException(
    this.message, {
    required this.ineligible,
    this.needsForeground = false,
    this.retryAfter,
  });

  final String message;
  final bool ineligible;
  final bool needsForeground;
  final Duration? retryAfter;

  /// Whether this instance holds the failure for its whole life.
  bool get permanent => ineligible || needsForeground;

  AttestationException _withRetryAfter(Duration d) => AttestationException(
    message,
    ineligible: ineligible,
    needsForeground: needsForeground,
    retryAfter: d,
  );

  @override
  String toString() =>
      'AttestationException($message, ineligible=$ineligible, '
      'needsForeground=$needsForeground, retryAfter=$retryAfter)';
}

/// Binds Google's verdict to one install and one challenge. Must match the
/// server's `attest.RequestHash` byte for byte: the ":" stops ("ab","cd") and
/// ("abc","d") colliding.
String requestHash(String installId, String challenge) =>
    sha256.convert(utf8.encode('$installId:$challenge')).toString();

/// Obtains and caches the proxy's session token: challenge, Play Integrity
/// token bound to it, exchange at `/v1/session`.
///
/// The token lives in [SecureStore] so every isolate shares it. Minting is
/// single-flight per instance; the UI isolate and a background isolate can
/// still race and mint two, which is harmless — each draws its own challenge
/// and the last write wins.
class AttestationService {
  AttestationService({
    required this.apiBase,
    required SecureStore store,
    required PlayIntegrity integrity,
    required Future<void> Function() onIneligible,
    http.Client? client,
    DateTime Function()? now,
    Duration integrityTimeout = AttestationService.integrityTimeout,
  }) : _store = store,
       _integrity = integrity,
       _onIneligible = onIneligible,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now,
       _integrityTimeout = integrityTimeout;

  final String apiBase;
  final SecureStore _store;
  final PlayIntegrity _integrity;
  final Future<void> Function() _onIneligible;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final Duration _integrityTimeout;

  /// Under this much validity left, a foreground [warmUp] renews early, so a
  /// background isolate — which cannot reach Play Integrity — rarely finds
  /// the token expired.
  static const Duration refreshMargin = Duration(hours: 2);

  /// Treat a token as expired slightly early so clock skew with the server
  /// cannot turn a "valid" token into a 401.
  static const Duration expirySkew = Duration(minutes: 1);

  static const Duration requestTimeout = Duration(seconds: 20);

  /// Cap on one Play Integrity request. Well inside the server's 2-minute
  /// challenge lifetime, and a hung Play Services must not leave the shared
  /// in-flight mint stuck forever.
  static const Duration integrityTimeout = Duration(seconds: 60);

  /// How long an ordinary failed mint is re-thrown before a new one is tried.
  /// Without it every queued message in a pass would draw its own challenge
  /// and Play Integrity request for the same outage.
  static const Duration failureCooldown = Duration(minutes: 3);

  Future<String>? _inflight;

  /// The last failed mint and when it happened; cleared by a success. An
  /// ineligible or [AttestationException.needsForeground] failure is held for
  /// the instance's life: neither changes within it, and instances are rebuilt
  /// per background run and on every mode flip.
  AttestationException? _failure;
  DateTime? _failedAt;

  /// When this instance last minted a session. Null for a session read from
  /// the keystore, whose mint time is unknown here.
  DateTime? _mintedAt;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// A usable session token, minting one when none is cached or it has
  /// expired. [forceRefresh] is for a 401: the server stopped honouring a
  /// token that still looks valid here.
  ///
  /// A forced refresh forgets the cached session before minting. In a
  /// background isolate the mint fails (no Play Integrity channel); without
  /// this the dead token would stay cached and every later background attempt
  /// would re-send it and get 401 again. Deleted, the next attempt and the
  /// UI's [warmUp] both see "no session", and the UI mints a fresh one.
  ///
  /// A remembered failure (see [failureCooldown]) is re-thrown instead of
  /// minting, forced or not.
  ///
  /// A forced refresh within [failureCooldown] of this instance's own mint
  /// throws a retryable error without network instead: the server is
  /// rejecting sessions it just issued (e.g. a rotated signing key), and
  /// minting again for every queued message would only repeat that. The
  /// session is kept; deleting it would just mean minting for the next row.
  Future<String> token({bool forceRefresh = false}) async {
    if (forceRefresh) {
      final mintedAt = _mintedAt;
      if (mintedAt != null) {
        final left = mintedAt.add(failureCooldown).difference(_now());
        if (left > Duration.zero) {
          throw AttestationException(
            'server rejected a fresh session',
            ineligible: false,
            retryAfter: left,
          );
        }
      }
      try {
        await _store.deleteSession();
      } catch (_) {
        // Best effort: the mint below overwrites it on success anyway.
      }
    } else {
      final cached = await _store.readSession();
      if (cached != null &&
          cached.expiresAt.subtract(expirySkew).isAfter(_now())) {
        return cached.token;
      }
    }
    return _mintOnce();
  }

  /// Foreground top-up, run at launch, resume and reconnect. Never throws: an
  /// ineligible result has already been reported, and anything else is
  /// retried on the next real use.
  ///
  /// Ignores a held transient failure and always tries once: it runs on
  /// reconnect and resume, exactly when a network failure may have cleared.
  /// A permanent one is still honoured.
  Future<void> warmUp() async {
    try {
      final cached = await _store.readSession();
      if (cached != null &&
          cached.expiresAt.difference(_now()) > refreshMargin) {
        return;
      }
      await _mintOnce(ignoreCooldown: true);
    } catch (_) {
      // See above.
    }
  }

  /// The server refused this install outright (403 on classify: banned).
  /// Never throws: the caller is already handling a failed request.
  ///
  /// Held as an ineligible failure, so the next message does not spend a
  /// challenge on a session the server will refuse.
  Future<void> reportRejected() async {
    _failure = const AttestationException(
      'install rejected by server',
      ineligible: true,
    );
    _failedAt = _now();
    try {
      await _store.deleteSession();
    } catch (_) {
      // A stale session is harmless: the server rejects it anyway.
    }
    await _flagIneligible();
  }

  /// Reports ineligibility without letting a failing callback replace the
  /// error the caller is about to see.
  Future<void> _flagIneligible() async {
    try {
      await _onIneligible();
    } catch (_) {
      // The flag is best effort; the next 403 sets it again.
    }
  }

  Future<String> _mintOnce({bool ignoreCooldown = false}) =>
      _inflight ??= _mintRemembered(
        ignoreCooldown: ignoreCooldown,
      ).whenComplete(() => _inflight = null);

  /// [_mint], unless a remembered failure is still held. A transient failure,
  /// fresh or held, carries the rest of its cooldown as
  /// [AttestationException.retryAfter], so the queue backs a row off past it
  /// and the row loses at most one attempt per outage.
  Future<String> _mintRemembered({required bool ignoreCooldown}) async {
    final held = _failure;
    if (held != null) {
      if (held.permanent) {
        // Reported again each time: cheap and idempotent, and it recovers a
        // first flag write that failed (the flag is best effort).
        if (held.ineligible) await _flagIneligible();
        throw held;
      }
      final left = _failedAt!.add(failureCooldown).difference(_now());
      if (!ignoreCooldown && left > Duration.zero) {
        throw held._withRetryAfter(left);
      }
    }
    try {
      final token = await _mint();
      _failure = null;
      _failedAt = null;
      _mintedAt = _now();
      return token;
    } on AttestationException catch (e) {
      _failure = e;
      _failedAt = _now();
      if (e.permanent) rethrow;
      throw e._withRetryAfter(failureCooldown);
    }
  }

  Future<String> _mint() async {
    final String installId;
    try {
      installId = await _store.installId();
    } catch (e) {
      throw AttestationException('keystore unavailable: $e', ineligible: false);
    }

    // Before the challenge: a background isolate learns it cannot reach Play
    // Integrity without spending one of the server's rate-limited challenges.
    try {
      await _integrity.ensureAvailable();
    } on IntegrityException catch (e) {
      throw _integrityFailure(e);
    } catch (_) {
      // Not a verdict on the channel; the token request below reports it.
    }

    final challenge = await _fetchChallenge();

    final String integrityToken;
    try {
      integrityToken = await _integrity
          .requestToken(requestHash(installId, challenge))
          .timeout(_integrityTimeout);
    } on TimeoutException {
      throw const AttestationException(
        'Play Integrity timed out',
        ineligible: false,
      );
    } on IntegrityException catch (e) {
      if (e.permanent) {
        await _flagIneligible();
        throw AttestationException(
          'Play Integrity unavailable on this device (${e.code})',
          ineligible: true,
        );
      }
      throw _integrityFailure(e);
    } catch (e) {
      throw AttestationException('Play Integrity error: $e', ineligible: false);
    }

    final resp = await _send(
      () => _client.post(
        Uri.parse('$apiBase/v1/session'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'installId': installId,
          'challenge': challenge,
          'integrityToken': integrityToken,
        }),
      ),
    );
    // 403 covers a failed verdict and a banned install. It also covers an
    // expired challenge, which is indistinguishable here and rare; the flag's
    // weekly expiry recovers that case. 503 means Google or the server is
    // unwell, never the device, so it is retried.
    if (resp.statusCode == 403) {
      await _flagIneligible();
      throw const AttestationException(
        'server rejected attestation',
        ineligible: true,
      );
    }
    if (resp.statusCode != 200) {
      throw AttestationException(
        'session HTTP ${resp.statusCode}',
        ineligible: false,
      );
    }

    final String token;
    final DateTime expiresAt;
    try {
      final obj = jsonDecode(resp.body) as Map<String, dynamic>;
      token = obj['token'] as String;
      expiresAt = DateTime.fromMillisecondsSinceEpoch(
        (obj['expiresAt'] as num).toInt() * 1000,
      );
    } catch (e) {
      throw AttestationException(
        'malformed session response: $e',
        ineligible: false,
      );
    }
    try {
      await _store.writeSession(token, expiresAt);
    } catch (_) {
      // Uncached: the token is still good, the next call just mints again.
    }
    return token;
  }

  /// A non-permanent Play Integrity failure, marking the no-channel case.
  AttestationException _integrityFailure(IntegrityException e) =>
      AttestationException(
        'Play Integrity failed (${e.code})',
        ineligible: false,
        needsForeground: e.code == PlayIntegrity.noActivity,
      );

  Future<String> _fetchChallenge() async {
    final resp = await _send(
      () => _client.get(Uri.parse('$apiBase/v1/challenge')),
    );
    if (resp.statusCode != 200) {
      throw AttestationException(
        'challenge HTTP ${resp.statusCode}',
        ineligible: false,
      );
    }
    try {
      return (jsonDecode(resp.body) as Map<String, dynamic>)['challenge']
          as String;
    } catch (e) {
      throw AttestationException('malformed challenge: $e', ineligible: false);
    }
  }

  Future<http.Response> _send(Future<http.Response> Function() call) async {
    try {
      return await call().timeout(requestTimeout);
    } catch (e) {
      throw AttestationException('network error: $e', ineligible: false);
    }
  }
}
