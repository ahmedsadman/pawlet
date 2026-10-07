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
}
