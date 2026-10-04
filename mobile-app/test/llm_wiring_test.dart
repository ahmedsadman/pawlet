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
}
