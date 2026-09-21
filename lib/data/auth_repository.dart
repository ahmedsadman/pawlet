import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists the app-lock secrets in the platform secure store (Android Keystore
/// backed). The PIN itself is never stored — only a salted SHA-256 hash.
class AuthRepository {
  AuthRepository(this._storage);

  final FlutterSecureStorage _storage;

  static const _kPinHash = 'pin_hash';
  static const _kPinSalt = 'pin_salt';
  static const _kBiometricEnabled = 'biometric_enabled';

  /// Whether a PIN has been set up (i.e. the app is past first-run).
  Future<bool> hasPin() async => (await _storage.read(key: _kPinHash)) != null;

  /// Stores a fresh random salt and the salted hash of [pin], replacing any
  /// existing PIN.
  Future<void> setPin(String pin) async {
    final salt = _randomSalt();
    await _storage.write(key: _kPinSalt, value: salt);
    await _storage.write(key: _kPinHash, value: _hash(pin, salt));
  }

  /// True when [pin] matches the stored hash.
  Future<bool> verifyPin(String pin) async {
    final salt = await _storage.read(key: _kPinSalt);
    final hash = await _storage.read(key: _kPinHash);
    if (salt == null || hash == null) return false;
    return _constantTimeEquals(_hash(pin, salt), hash);
  }

  /// Whether the user opted into biometric unlock.
  Future<bool> get biometricEnabled async =>
      (await _storage.read(key: _kBiometricEnabled)) == 'true';

  Future<void> setBiometricEnabled(bool value) =>
      _storage.write(key: _kBiometricEnabled, value: value.toString());

  static String _randomSalt() {
    final rng = Random.secure();
    return base64Encode(List<int>.generate(16, (_) => rng.nextInt(256)));
  }

  static String _hash(String pin, String salt) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  /// Length-then-content compare that doesn't short-circuit on the first
  /// differing byte, avoiding a timing side channel on the hash comparison.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }
}
