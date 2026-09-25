import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Encrypted key-value storage (Android Keystore-backed) for secrets that must
/// not live in SharedPreferences — currently the OpenRouter API key.
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

  /// Resolves the API key for the pipeline: the stored key if present, else the
  /// compile-time `--dart-define=OPENROUTER_API_KEY` value (persisted for next
  /// launch so it survives even if the define is later dropped). Returns '' when
  /// neither is set. No key baked into a client binary is truly secret, but this
  /// keeps it out of source control and out of plaintext prefs.
  Future<String> resolveApiKey() async {
    final stored = await readApiKey();
    if (stored.isNotEmpty) return stored;
    const injected = String.fromEnvironment('OPENROUTER_API_KEY');
    if (injected.isNotEmpty) {
      await writeApiKey(injected);
      return injected;
    }
    return '';
  }
}
