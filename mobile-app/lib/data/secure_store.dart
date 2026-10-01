import 'package:flutter/foundation.dart';
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

  /// The compile-time `--dart-define=OPENROUTER_API_KEY` value, '' when unset.
  @visibleForTesting
  String get injectedApiKey =>
      const String.fromEnvironment('OPENROUTER_API_KEY');

  /// Resolves the API key for the pipeline: the compile-time
  /// `--dart-define=OPENROUTER_API_KEY` value if set, else the stored key
  /// (so a build that drops the define keeps working). Returns '' when neither
  /// is set. No key baked into a client binary is truly secret, but this keeps
  /// it out of source control and out of plaintext prefs.
  ///
  /// The define outranks the store so that rotating the key is just a rebuild.
  /// The other way round, a key persisted on first launch outlives every later
  /// build, and once it is revoked the pipeline fails every message with a
  /// non-retryable 401 that no reinstall-free action can clear — there is no
  /// in-app writer for this key.
  Future<String> resolveApiKey() async {
    final injected = injectedApiKey.trim();
    final stored = await readApiKey();
    if (injected.isEmpty) return stored;
    if (injected != stored) await writeApiKey(injected);
    return injected;
  }
}
