import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/finance_repository.dart';
import 'package:meowni/data/secure_store.dart';
import 'package:meowni/models/finance/bank.dart';
import 'package:meowni/state/finance_providers.dart';
import 'package:meowni/state/providers.dart';
import 'package:meowni/theme/catppuccin_theme.dart';
import 'package:meowni/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory SecureStore so tests never touch the platform keystore.
class _FakeSecureStore extends SecureStore {
  String key = '';
  @override
  Future<String> readApiKey() async => key;
  @override
  Future<void> writeApiKey(String value) async => key = value.trim();
}

Future<(Widget, ProviderContainer)> _app(List<Override> extra) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bootstrapApiKeyProvider.overrideWithValue(''),
      secureStoreProvider.overrideWith((ref) => _FakeSecureStore()),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  final widget = UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: AppTheme.theme, home: const SettingsPage()),
  );
  return (widget, container);
}

void main() {
  testWidgets('renders the key, model, currency and manage-banks controls', (
    tester,
  ) async {
    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    expect(find.widgetWithText(TextField, 'API key'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Model'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Normalized currency'), findsOneWidget);
    expect(find.text('Manage banks'), findsOneWidget);
    expect(find.text('Resolve contact names'), findsOneWidget);
  });

  testWidgets('saving AI settings persists the key and model', (tester) async {
    final (widget, container) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.enterText(find.widgetWithText(TextField, 'API key'), 'sk-test');
    await tester.enterText(find.widgetWithText(TextField, 'Model'), 'vendor/model');
    await tester.tap(find.widgetWithText(FilledButton, 'Save').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(container.read(apiKeyProvider), 'sk-test');
    expect(container.read(settingsRepositoryProvider).llmModel, 'vendor/model');
  });

  testWidgets('saving currency upper-cases and persists it', (tester) async {
    final (widget, container) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.enterText(
      find.widgetWithText(TextField, 'Normalized currency'),
      'usd',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pump();

    expect(container.read(settingsRepositoryProvider).currency, 'USD');
  });

  testWidgets('Manage banks navigates to the Banks page', (tester) async {
    final (widget, _) = await _app([
      banksProvider.overrideWith(
        (ref) async => const CachedResult(data: <Bank>[]),
      ),
    ]);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.tap(find.text('Manage banks'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Banks'), findsOneWidget);
    expect(find.text('No banks yet'), findsOneWidget);
  });
}
