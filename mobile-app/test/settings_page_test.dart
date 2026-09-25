import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<(Widget, ProviderContainer)> _app(List<Override> extra) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs), ...extra],
  );
  addTearDown(container.dispose);
  final widget = UncontrolledProviderScope(
    container: container,
    child: MaterialApp(theme: AppTheme.theme, home: const SettingsPage()),
  );
  return (widget, container);
}

void main() {
  testWidgets(
    'renders currency toggle, manage-banks and privacy — no AI fields',
    (tester) async {
      final (widget, _) = await _app(const []);
      await tester.pumpWidget(widget);
      await tester.pump();

      // AI (OpenRouter) section is gone.
      expect(find.text('AI (OpenRouter)'), findsNothing);
      expect(find.widgetWithText(TextField, 'API key'), findsNothing);
      expect(find.widgetWithText(TextField, 'Model'), findsNothing);

      // Currency is a BDT/USD segmented toggle (no free-text field).
      expect(find.byType(SegmentedButton<String>), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Normalized currency'),
        findsNothing,
      );

      expect(find.text('Manage Banks & Cards'), findsOneWidget);
      expect(find.text('Resolve contact names'), findsOneWidget);

      // Privacy sits near the bottom of the (lazy) ListView — scroll it in.
      await tester.dragUntilVisible(
        find.text('Privacy'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Privacy'), findsOneWidget);
      expect(find.textContaining('stays on this device'), findsOneWidget);
    },
  );

  testWidgets('selecting a currency persists it', (tester) async {
    final (widget, container) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    expect(container.read(settingsRepositoryProvider).currency, 'BDT');
    await tester.tap(find.text('USD'));
    await tester.pump();

    expect(container.read(settingsRepositoryProvider).currency, 'USD');
  });

  testWidgets('Manage Banks & Cards navigates to the Banks page', (
    tester,
  ) async {
    final (widget, _) = await _app([
      banksProvider.overrideWith(
        (ref) async => const CachedResult(data: <Bank>[]),
      ),
    ]);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.tap(find.text('Manage Banks & Cards'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Banks & Cards'), findsOneWidget);
    expect(find.text('No banks yet'), findsOneWidget);
  });

  testWidgets('Backup & Restore navigates to the backup page', (tester) async {
    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Backup & Restore'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('Backup & Restore'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, 'Backup & Restore'), findsOneWidget);
    expect(find.text('Back up to file'), findsOneWidget);
    expect(find.text('Restore from file'), findsOneWidget);
  });
}
