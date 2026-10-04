import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/secure_store.dart';

/// In-memory store: overrides the read/write/delete seams so the tests run
/// against a fake instead of the platform keystore.
class _FakeStore extends SecureStore {
  String? key;

  @override
  Future<String> readApiKey() async => key ?? '';

  @override
  Future<void> writeApiKey(String value) async => key = value.trim();

  @override
  Future<void> deleteApiKey() async => key = null;
}

void main() {
  test('an unset key reads as empty', () async {
    expect(await _FakeStore().readApiKey(), '');
  });

  test('a written key reads back trimmed', () async {
    final s = _FakeStore();
    await s.writeApiKey('  sk-or-pad\n');
    expect(await s.readApiKey(), 'sk-or-pad');
  });

  test('deleting leaves nothing behind', () async {
    final s = _FakeStore()..key = 'sk-or-old';
    await s.deleteApiKey();
    expect(await s.readApiKey(), '');
  });
}
