import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/secure_store.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:pawlet/state/providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeStore extends SecureStore {
  String? key;

  @override
  Future<String> readApiKey() async => key ?? '';

  @override
  Future<void> writeApiKey(String value) async => key = value.trim();

  @override
  Future<void> deleteApiKey() async => key = null;
}

Future<ProviderContainer> _container({
  String bootstrapKey = '',
  bool fromPlay = false,
  SecureStore? store,
}) async {
  SharedPreferences.setMockInitialValues({'installed_from_play': fromPlay});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bootstrapApiKeyProvider.overrideWithValue(bootstrapKey),
      if (store != null) secureStoreProvider.overrideWithValue(store),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('no key and no server means no LLM', () async {
    final c = await _container();
    expect(c.read(llmModeProvider), LlmMode.none);
  });

  test('a stored key switches the mode to byok', () async {
    final c = await _container(bootstrapKey: 'sk-or-stored');
    expect(c.read(llmModeProvider), LlmMode.byok);
  });

  test('saving a key flips the mode without a restart', () async {
    final store = _FakeStore();
    final c = await _container(store: store);
    expect(c.read(llmModeProvider), LlmMode.none);

    await c.read(apiKeyProvider.notifier).save('  sk-or-new  ');

    expect(store.key, 'sk-or-new');
    expect(c.read(apiKeyProvider), 'sk-or-new');
    expect(c.read(llmModeProvider), LlmMode.byok);
  });

  test('clearing the key flips the mode back', () async {
    final store = _FakeStore()..key = 'sk-or-old';
    final c = await _container(bootstrapKey: 'sk-or-old', store: store);
    expect(c.read(llmModeProvider), LlmMode.byok);

    await c.read(apiKeyProvider.notifier).clear();

    expect(store.key, isNull);
    expect(c.read(llmModeProvider), LlmMode.none);
  });

  test('a Play install with no server configured still has no proxy', () async {
    // PAWLET_API_BASE is unset in the test runner, which is also true of every
    // build this stage produces.
    final c = await _container(fromPlay: true, bootstrapKey: 'sk-or-stored');
    expect(c.read(llmModeProvider), LlmMode.byok);
  });

  test('seeded attestation_ineligible flag is read by the provider', () async {
    SharedPreferences.setMockInitialValues({'attestation_ineligible': true});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        bootstrapApiKeyProvider.overrideWithValue('sk-or-stored'),
      ],
    );
    addTearDown(c.dispose);

    expect(c.read(attestationIneligibleProvider), isTrue);
    expect(c.read(llmModeProvider), LlmMode.byok);
  });

  test('setting the flag updates the provider and persists', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        bootstrapApiKeyProvider.overrideWithValue(''),
      ],
    );
    addTearDown(c.dispose);

    expect(c.read(attestationIneligibleProvider), isFalse);

    await c.read(attestationIneligibleProvider.notifier).set(true);

    expect(c.read(attestationIneligibleProvider), isTrue);
    // Verify persistence: the value was written to SharedPreferences and can
    // be read back directly.
    expect(prefs.getBool('attestation_ineligible'), isTrue);
  });

  test('sync pulls in a flag another code path wrote to prefs', () async {
    final c = await _container(fromPlay: true);
    expect(c.read(attestationIneligibleProvider), isFalse);

    // Another isolate's write: it lands in the platform store but not in this
    // isolate's SharedPreferences cache, which sync() has to reload.
    SharedPreferences.setMockInitialValues({
      'installed_from_play': true,
      'attestation_ineligible': true,
    });
    expect(c.read(attestationIneligibleProvider), isFalse);

    await c.read(attestationIneligibleProvider.notifier).sync();
    expect(c.read(attestationIneligibleProvider), isTrue);
  });

  test('sync leaves the state alone when skipIf says so', () async {
    final c = await _container(fromPlay: true);
    SharedPreferences.setMockInitialValues({
      'installed_from_play': true,
      'attestation_ineligible': true,
    });

    await c
        .read(attestationIneligibleProvider.notifier)
        .sync(skipIf: () => true);
    expect(c.read(attestationIneligibleProvider), isFalse);
  });
}
