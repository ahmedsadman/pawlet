import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted key-value storage (Android Keystore-backed) for secrets that must
/// not live in SharedPreferences — currently the user's OpenRouter API key.
///
/// The key is written only by the bring-your-own-key input in Settings and
/// read only by the pipeline. Nothing is baked into the binary: a key in a
/// client APK is extractable, which is why the proxy exists.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kApiKey = 'llm_api_key';

  /// Written alongside every key the user saves. Older builds copied their
  /// baked-in key into [_kApiKey] on each launch without it, so a key missing
  /// this marker is Pawlet's old shared key, not the user's, and is dropped
  /// rather than silently turning the install into bring-your-own-key.
  static const _kUserOwned = 'llm_api_key_user_owned';

  static const _kInstallId = 'install_id';
  static const _kSessionToken = 'session_token';
  static const _kSessionExpiresAt = 'session_expires_at';

  Future<String> readApiKey() async {
    try {
      final key = await _storage.read(key: _kApiKey);
      if (key == null) return '';
      if (await _storage.read(key: _kUserOwned) == null) {
        await _storage.delete(key: _kApiKey);
        return '';
      }
      return key;
    } catch (_) {
      // A corrupted/locked keystore entry must not crash startup — treat as
      // "no key set" so the user can re-enter it in Settings.
      return '';
    }
  }

  Future<void> writeApiKey(String value) async {
    // Marker first: a background isolate reading between the two writes must
    // never see the new key without its marker and delete it.
    await _storage.write(key: _kUserOwned, value: '1');
    await _storage.write(key: _kApiKey, value: value.trim());
  }

  Future<void> deleteApiKey() async {
    await _storage.delete(key: _kApiKey);
    await _storage.delete(key: _kUserOwned);
  }

  /// The anonymous identity this install attests under: 256 random bits as
  /// hex, created on first use and kept for the life of the install. The
  /// server only ever stores its SHA-256.
  ///
  /// Two isolates racing on first use can each write one; the last write
  /// wins, and a session minted under the losing ID simply expires.
  Future<String> installId() async {
    final existing = await _storage.read(key: _kInstallId);
    if (existing != null && existing.isNotEmpty) return existing;
    final rng = Random.secure();
    final id = List.generate(
      32,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    await _storage.write(key: _kInstallId, value: id);
    return id;
  }

  /// The cached proxy session. Here rather than in memory so the WorkManager
  /// and background-SMS isolates, which cannot mint one, can still use it.
  Future<({String token, DateTime expiresAt})?> readSession() async {
    try {
      final token = await _storage.read(key: _kSessionToken);
      final expires = int.tryParse(
        await _storage.read(key: _kSessionExpiresAt) ?? '',
      );
      if (token == null || token.isEmpty || expires == null) return null;
      return (
        token: token,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(expires),
      );
    } catch (_) {
      // A locked or corrupted entry just means "mint a new one".
      return null;
    }
  }

  Future<void> writeSession(String token, DateTime expiresAt) async {
    await _storage.write(
      key: _kSessionExpiresAt,
      value: '${expiresAt.millisecondsSinceEpoch}',
    );
    await _storage.write(key: _kSessionToken, value: token);
  }

  Future<void> deleteSession() async {
    await _storage.delete(key: _kSessionToken);
    await _storage.delete(key: _kSessionExpiresAt);
  }
}
