import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted key-value storage (Android Keystore-backed) for secrets that must
/// not live in SharedPreferences — currently the OpenRouter API key.
class SecureStore {
  SecureStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _kApiKey = 'llm_api_key';

  Future<String> readApiKey() async =>
      (await _storage.read(key: _kApiKey)) ?? '';

  Future<void> writeApiKey(String value) =>
      _storage.write(key: _kApiKey, value: value.trim());
}
