import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/finance_repository.dart';
import 'package:pawlet/models/finance/bank.dart';
import 'package:pawlet/services/app_update_service.dart';
import 'package:pawlet/services/llm/llm_mode.dart';
import 'package:pawlet/services/privacy_policy.dart';
import 'package:pawlet/state/finance_providers.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/play_update_fakes.dart';

Future<(Widget, ProviderContainer)> _app(
  List<Override> extra, {
  Map<String, Object> prefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final instance = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(instance),
      bootstrapApiKeyProvider.overrideWithValue(''),
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
  testWidgets(
    'renders manage-banks and privacy — no currency/contact/AI fields',
    (tester) async {
      final (widget, _) = await _app(const []);
      await tester.pumpWidget(widget);
      await tester.pump();

      // AI (OpenRouter) section is gone.
      expect(find.text('AI (OpenRouter)'), findsNothing);

      // Currency toggle and contact toggle are gone.
      expect(find.byType(SegmentedButton<String>), findsNothing);
      expect(find.text('Resolve contact names'), findsNothing);

      expect(find.text('Manage Banks & Cards'), findsOneWidget);

      // Privacy sits near the bottom of the (lazy) ListView — scroll it in.
      await tester.dragUntilVisible(
        find.text('Privacy'),
        find.byType(ListView),
        const Offset(0, -200),
      );
      expect(find.text('Privacy'), findsOneWidget);
      expect(
        find.textContaining('Your messages never leave your phone'),
        findsOneWidget,
      );
    },
  );

  testWidgets('privacy copy and the key input follow the resolved mode', (
    tester,
  ) async {
    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    // Privacy sits near the bottom of the (lazy) ListView — scroll it in.
    await tester.dragUntilVisible(
      find.text('Privacy'),
      find.byType(ListView),
      const Offset(0, -200),
    );

    expect(
      find.textContaining('Your messages never leave your phone'),
      findsOneWidget,
    );

    // The BYOK section sits below Privacy, scroll it in.
    await tester.dragUntilVisible(
      find.text('Use LLM to improve accuracy'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('Use LLM to improve accuracy'), findsOneWidget);
  });

  testWidgets('proxy mode shows Pawlet service copy and no key input', (
    tester,
  ) async {
    final (widget, _) = await _app([
      llmModeProvider.overrideWithValue(LlmMode.proxy),
    ]);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Privacy'),
      find.byType(ListView),
      const Offset(0, -200),
    );

    expect(find.textContaining("Pawlet's service"), findsOneWidget);
    expect(find.text('Use LLM to improve accuracy'), findsNothing);
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

  testWidgets('Data section offers the inbox import', (tester) async {
    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Import existing messages'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('Import existing messages'), findsOneWidget);
    expect(find.textContaining('Scan your SMS inbox'), findsOneWidget);
  });

  testWidgets('the privacy policy tile opens the hosted policy', (
    tester,
  ) async {
    Uri? launched;
    PrivacyPolicy.launcher = (uri) async {
      launched = uri;
      return true;
    };
    addTearDown(PrivacyPolicy.resetLauncher);

    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Privacy policy'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(launched, Uri.parse(PrivacyPolicy.url));
  });

  testWidgets('a failed launch tells the user instead of failing silently', (
    tester,
  ) async {
    PrivacyPolicy.launcher = (_) async => false;
    addTearDown(PrivacyPolicy.resetLauncher);

    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Privacy policy'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('Privacy policy'));
    await tester.pumpAndSettle();

    expect(find.text('Could not open your browser'), findsOneWidget);
  });

  testWidgets('Check for updates runs a manual check on Play installs', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(); // Play says: up to date.
    final (widget, _) = await _app(
      [
        // Built from the container's own settings, so it sees the seeded
        // installed_from_play flag.
        appUpdateServiceProvider.overrideWith(
          (ref) => AppUpdateService(
            api: api,
            settings: ref.watch(settingsRepositoryProvider),
          ),
        ),
      ],
      prefs: {'installed_from_play': true},
    );
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Check for updates'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(api.checkCalls, 1);
    expect(find.text("You're on the latest version"), findsOneWidget);
  });

  testWidgets('Check for updates is hidden on sideloaded installs', (
    tester,
  ) async {
    final (widget, _) = await _app(const []);
    await tester.pumpWidget(widget);
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Privacy policy'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    expect(find.text('Check for updates'), findsNothing);
  });
}
