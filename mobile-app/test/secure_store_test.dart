import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/secure_store.dart';

/// In-memory store: overrides the read/write and compile-time-define seams so
/// [SecureStore.resolveApiKey] runs against fakes instead of the platform
/// keystore and the real `--dart-define`.
class _FakeStore extends SecureStore {
  String key = '';
  String define = '';
  int writes = 0;

  @override
  Future<String> readApiKey() async => key;

  @override
  Future<void> writeApiKey(String value) async {
    writes++;
    key = value.trim();
  }

  @override
  String get injectedApiKey => define;
}

void main() {
  test(
    'resolveApiKey prefers the injected key over a stale stored one',
    () async {
      final s = _FakeStore()
        ..key = 'sk-stale'
        ..define = 'sk-fresh';
      expect(await s.resolveApiKey(), 'sk-fresh');
      expect(s.key, 'sk-fresh'); // stale key replaced
    },
  );

  test(
    'resolveApiKey persists the injected key when nothing is stored',
    () async {
      final s = _FakeStore()..define = 'sk-fresh';
      expect(await s.resolveApiKey(), 'sk-fresh');
      expect(s.key, 'sk-fresh');
    },
  );

  test(
    'resolveApiKey does not rewrite when the injected key already matches',
    () async {
      final s = _FakeStore()
        ..key = 'sk-same'
        ..define = 'sk-same';
      expect(await s.resolveApiKey(), 'sk-same');
      expect(s.writes, 0);
    },
  );

  test(
    'resolveApiKey ignores surrounding whitespace on the injected key',
    () async {
      final s = _FakeStore()
        ..key = 'sk-same'
        ..define = '  sk-same\n';
      expect(await s.resolveApiKey(), 'sk-same');
      expect(s.writes, 0); // trimmed define equals stored, so no churn
    },
  );

  test(
    'resolveApiKey falls back to the stored key when the define is dropped',
    () async {
      final s = _FakeStore()..key = 'sk-stored';
      expect(await s.resolveApiKey(), 'sk-stored');
      expect(s.writes, 0); // untouched
    },
  );

  test(
    'resolveApiKey returns empty when nothing stored and no --dart-define',
    () async {
      final s = _FakeStore();
      expect(await s.resolveApiKey(), '');
      expect(s.key, ''); // nothing persisted
    },
  );
}
