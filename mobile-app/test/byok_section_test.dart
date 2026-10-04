import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/secure_store.dart';
import 'package:pawlet/services/llm/key_validator.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/settings/byok_section.dart';
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

/// Answers with a canned verdict and records what it was asked about, so the
/// tests never touch the network.
class _FakeValidator extends OpenRouterKeyValidator {
  _FakeValidator(this.result);
  final KeyCheck result;
  String? seen;

  @override
  Future<KeyCheck> check(String key) async {
    seen = key;
    return result;
  }

  @override
  void close() {}
}

class _ThrowingStore extends SecureStore {
  @override
  Future<String> readApiKey() async => '';

  @override
  Future<void> writeApiKey(String value) async {
    throw Exception('Keystore locked');
  }

  @override
  Future<void> deleteApiKey() async {}
}

Future<(Widget, _FakeStore)> _host({
  KeyCheck verdict = KeyCheck.valid,
  String storedKey = '',
  bool ineligible = false,
  _FakeValidator? validator,
}) async {
  SharedPreferences.setMockInitialValues({
    'attestation_ineligible': ineligible,
  });
  final prefs = await SharedPreferences.getInstance();
  final store = _FakeStore()..key = storedKey.isEmpty ? null : storedKey;
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bootstrapApiKeyProvider.overrideWithValue(storedKey),
      secureStoreProvider.overrideWithValue(store),
      keyValidatorProvider.overrideWithValue(
        validator ?? _FakeValidator(verdict),
      ),
    ],
  );
  addTearDown(container.dispose);
  return (
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: SingleChildScrollView(child: ByokSection())),
      ),
    ),
    store,
  );
}

Future<(Widget, _ThrowingStore)> _hostThrowingStore() async {
  SharedPreferences.setMockInitialValues({'attestation_ineligible': false});
  final prefs = await SharedPreferences.getInstance();
  final store = _ThrowingStore();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bootstrapApiKeyProvider.overrideWithValue(''),
      secureStoreProvider.overrideWithValue(store),
      keyValidatorProvider.overrideWithValue(_FakeValidator(KeyCheck.valid)),
    ],
  );
  addTearDown(container.dispose);
  return (
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.theme,
        home: const Scaffold(body: SingleChildScrollView(child: ByokSection())),
      ),
    ),
    store,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('explains what the key is for and where to get one', (
    tester,
  ) async {
    final (widget, _) = await _host();
    await tester.pumpWidget(widget);

    expect(find.text('Use LLM to improve accuracy'), findsOneWidget);
    expect(find.textContaining('openrouter.ai/keys'), findsOneWidget);
    expect(find.textContaining('on-device model handles most'), findsOneWidget);
  });

  testWidgets('a valid key is stored and the input cleared', (tester) async {
    final (widget, store) = await _host();
    await tester.pumpWidget(widget);

    await tester.enterText(find.byType(TextField), 'sk-or-good');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(store.key, 'sk-or-good');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('a rejected key reports inline and stores nothing', (
    tester,
  ) async {
    final (widget, store) = await _host(verdict: KeyCheck.invalid);
    await tester.pumpWidget(widget);

    await tester.enterText(find.byType(TextField), 'sk-or-bad');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Invalid key'), findsOneWidget);
    expect(store.key, isNull);
  });

  testWidgets('an unreachable check is worded differently from a bad key', (
    tester,
  ) async {
    // A bad connection must never read as a bad key.
    final (widget, store) = await _host(verdict: KeyCheck.unreachable);
    await tester.pumpWidget(widget);

    await tester.enterText(find.byType(TextField), 'sk-or-maybe');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't reach OpenRouter"), findsOneWidget);
    expect(find.text('Invalid key'), findsNothing);
    expect(store.key, isNull);
  });

  testWidgets('the key is trimmed before it is checked', (tester) async {
    final validator = _FakeValidator(KeyCheck.valid);
    final (widget, store) = await _host(validator: validator);
    await tester.pumpWidget(widget);

    await tester.enterText(find.byType(TextField), '  sk-or-pad  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(validator.seen, 'sk-or-pad');
    expect(store.key, 'sk-or-pad');
  });

  testWidgets('Save with an empty field asks for a key, no request', (
    tester,
  ) async {
    final validator = _FakeValidator(KeyCheck.valid);
    final (widget, _) = await _host(validator: validator);
    await tester.pumpWidget(widget);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a key first'), findsOneWidget);
    expect(validator.seen, isNull);
  });

  testWidgets('Remove appears only once a key is stored', (tester) async {
    final (empty, _) = await _host();
    await tester.pumpWidget(empty);
    expect(find.text('Remove key'), findsNothing);

    final (stored, store) = await _host(storedKey: 'sk-or-old');
    await tester.pumpWidget(stored);
    await tester.pumpAndSettle();
    expect(find.text('Remove key'), findsOneWidget);

    await tester.tap(find.text('Remove key'));
    await tester.pumpAndSettle();

    expect(store.key, isNull);
    expect(find.text('Remove key'), findsNothing);
  });

  testWidgets('an attestation-ineligible device gets the extra explanation', (
    tester,
  ) async {
    final (plain, _) = await _host();
    await tester.pumpWidget(plain);
    expect(find.textContaining('integrity check'), findsNothing);

    final (flagged, _) = await _host(ineligible: true);
    await tester.pumpWidget(flagged);
    expect(find.textContaining('integrity check'), findsOneWidget);
  });

  testWidgets('a keystore write failure surfaces instead of crashing', (
    tester,
  ) async {
    // SecureStore.writeApiKey can throw on a locked or corrupted keystore.
    // Without handling, the exception escapes the button handler and the user
    // sees a spinner that never resolves.
    final (widget, _) = await _hostThrowingStore();
    await tester.pumpWidget(widget);

    await tester.enterText(find.byType(TextField), 'sk-or-good');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text("Couldn't save the key"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
