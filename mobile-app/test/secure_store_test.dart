import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('an unset key reads as empty', () async {
    expect(await SecureStore().readApiKey(), '');
  });

  test('a written key reads back trimmed', () async {
    final s = SecureStore();
    await s.writeApiKey('  sk-or-pad\n');
    expect(await s.readApiKey(), 'sk-or-pad');
  });

  test('deleting leaves nothing behind', () async {
    final s = SecureStore();
    await s.writeApiKey('sk-or-old');
    await s.deleteApiKey();
    expect(await s.readApiKey(), '');
  });

  test('a key persisted by an older build is discarded, not adopted', () async {
    // Older builds copied their baked-in key into this slot on every launch.
    // It was never the user's, so it must not turn the install into byok.
    FlutterSecureStorage.setMockInitialValues({'llm_api_key': 'sk-or-baked'});
    final s = SecureStore();
    expect(await s.readApiKey(), '');
    expect(await const FlutterSecureStorage().read(key: 'llm_api_key'), isNull);
  });

  test('a key saved after the legacy one was dropped is kept', () async {
    FlutterSecureStorage.setMockInitialValues({'llm_api_key': 'sk-or-baked'});
    final s = SecureStore();
    await s.readApiKey();
    await s.writeApiKey('sk-or-mine');
    expect(await s.readApiKey(), 'sk-or-mine');
  });

  test('the install ID is 64 hex chars and stable across reads', () async {
    final s = SecureStore();
    final id = await s.installId();
    expect(id, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await SecureStore().installId(), id);
  });

  test('a session round-trips with its expiry', () async {
    final s = SecureStore();
    final at = DateTime.fromMillisecondsSinceEpoch(1791394932000);
    await s.writeSession('jwt', at);
    final read = await s.readSession();
    expect(read!.token, 'jwt');
    expect(read.expiresAt, at);
  });

  test('no session reads as null, and deleting clears it', () async {
    final s = SecureStore();
    expect(await s.readSession(), isNull);
    await s.writeSession('jwt', DateTime(2030));
    await s.deleteSession();
    expect(await s.readSession(), isNull);
  });
}
