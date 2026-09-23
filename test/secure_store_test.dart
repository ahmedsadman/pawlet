import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/secure_store.dart';

/// In-memory store: overrides the read/write seams so [SecureStore.resolveApiKey]
/// runs against fakes instead of the platform keystore.
class _FakeStore extends SecureStore {
  String key = '';
  @override
  Future<String> readApiKey() async => key;
  @override
  Future<void> writeApiKey(String value) async => key = value.trim();
}

void main() {
  test(
    'resolveApiKey returns the stored key and does not overwrite it',
    () async {
      final s = _FakeStore()..key = 'sk-stored';
      expect(await s.resolveApiKey(), 'sk-stored');
      expect(s.key, 'sk-stored'); // untouched
    },
  );

  test(
    'resolveApiKey returns empty when nothing stored and no --dart-define',
    () async {
      // Tests run without --dart-define=OPENROUTER_API_KEY, so the fallback is ''.
      // The injected→persisted branch is only reachable with a compile-time
      // define, so it cannot be exercised from unit tests (harness limitation).
      final s = _FakeStore();
      expect(await s.resolveApiKey(), '');
      expect(s.key, ''); // nothing persisted
    },
  );
}
