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

  Future<String> readApiKey() async {
    try {
      return (await _storage.read(key: _kApiKey)) ?? '';
    } catch (_) {
      // A corrupted/locked keystore entry must not crash startup — treat as
      // "no key set" so the user can re-enter it in Settings.
      return '';
    }
  }

  Future<void> writeApiKey(String value) =>
      _storage.write(key: _kApiKey, value: value.trim());

  Future<void> deleteApiKey() => _storage.delete(key: _kApiKey);
}
