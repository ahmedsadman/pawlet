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
class AttestationException implements Exception {
  const AttestationException(this.message, {required this.ineligible});

  final String message;
  final bool ineligible;

  @override
  String toString() => 'AttestationException($message, ineligible=$ineligible)';
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
  }) : _store = store,
       _integrity = integrity,
       _onIneligible = onIneligible,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _now = now ?? DateTime.now;

  final String apiBase;
  final SecureStore _store;
  final PlayIntegrity _integrity;
  final Future<void> Function() _onIneligible;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;

  /// Under this much validity left, a foreground [warmUp] renews early, so a
  /// background isolate — which cannot reach Play Integrity — rarely finds
  /// the token expired.
  static const Duration refreshMargin = Duration(hours: 2);

  /// Treat a token as expired slightly early so clock skew with the server
  /// cannot turn a "valid" token into a 401.
  static const Duration expirySkew = Duration(minutes: 1);

  static const Duration requestTimeout = Duration(seconds: 20);

  Future<String>? _inflight;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// A usable session token, minting one when none is cached or it has
  /// expired. [forceRefresh] is for a 401: the server stopped honouring a
  /// token that still looks valid here.
  Future<String> token({bool forceRefresh = false}) async {
    if (!forceRefresh) {
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
  Future<void> warmUp() async {
    try {
      final cached = await _store.readSession();
      if (cached != null &&
          cached.expiresAt.difference(_now()) > refreshMargin) {
        return;
      }
      await _mintOnce();
    } on AttestationException {
      // See above.
    }
  }

  /// The server refused this install outright (403 on classify: banned).
  Future<void> reportRejected() async {
    await _store.deleteSession();
    await _onIneligible();
  }

  Future<String> _mintOnce() =>
      _inflight ??= _mint().whenComplete(() => _inflight = null);

  Future<String> _mint() async {
    final String installId;
    try {
      installId = await _store.installId();
    } catch (e) {
      throw AttestationException('keystore unavailable: $e', ineligible: false);
    }

    final challenge = await _fetchChallenge();

    final String integrityToken;
    try {
      integrityToken = await _integrity.requestToken(
        requestHash(installId, challenge),
      );
    } on IntegrityException catch (e) {
      if (e.permanent) {
        await _onIneligible();
        throw AttestationException(
          'Play Integrity unavailable on this device (${e.code})',
          ineligible: true,
        );
      }
      throw AttestationException(
        'Play Integrity failed (${e.code})',
        ineligible: false,
      );
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
      await _onIneligible();
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
