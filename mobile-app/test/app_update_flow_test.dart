import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/services/app_update_service.dart';
import 'package:pawlet/state/providers.dart';
import 'package:pawlet/theme/catppuccin_theme.dart';
import 'package:pawlet/ui/app_update_flow.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/play_update_fakes.dart';

final _now = DateTime(2026, 10, 9, 12);

/// Pumps a button that runs the flow, taps it, and settles.
Future<SettingsRepository> _run(
  WidgetTester tester,
  FakePlayUpdateApi api, {
  bool manual = false,
  bool fromPlay = true,
  DateTime? snoozedUntil,
  bool Function()? canPrompt,
}) async {
  SharedPreferences.setMockInitialValues({
    'installed_from_play': fromPlay,
    if (snoozedUntil != null)
      'update_prompt_snoozed_until': snoozedUntil.millisecondsSinceEpoch,
  });
  final settings = SettingsRepository(await SharedPreferences.getInstance());
  final service = AppUpdateService(
    api: api,
    settings: settings,
    now: () => _now,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => runAppUpdateCheck(
                  context,
                  ref,
                  manual: manual,
                  canPrompt: canPrompt ?? () => true,
                ),
                child: const Text('check'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('check'));
  await tester.pumpAndSettle();
  return settings;
}

void main() {
  const offerTitle = 'A new version is ready';

  testWidgets('an available update is offered, downloaded, then restarted', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    await _run(tester, api);

    expect(find.text(offerTitle), findsOneWidget);
    expect(find.textContaining('Downloads in the background'), findsOneWidget);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(api.startCalls, 1);
    expect(find.text(offerTitle), findsNothing);
    expect(find.text('Update downloaded'), findsOneWidget);

    await tester.tap(find.text('Restart'));
    await tester.pump();
    expect(api.completeCalls, 1);
  });

  testWidgets('Not now snoozes the automatic prompt for three days', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = await _run(tester, api);

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(api.startCalls, 0);
    expect(
      settings.updatePromptSnoozedUntil,
      _now.add(const Duration(days: 3)),
    );
  });

  testWidgets('dismissing the sheet counts as Not now', (tester) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = await _run(tester, api);

    // Tap the scrim above the sheet.
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    expect(api.startCalls, 0);
    expect(settings.updatePromptSnoozedUntil, isNotNull);
  });

  testWidgets('a snoozed update stays quiet on the automatic check', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    await _run(tester, api, snoozedUntil: _now.add(const Duration(days: 1)));
    expect(find.text(offerTitle), findsNothing);
  });

  testWidgets('the manual check ignores the snooze', (tester) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    await _run(
      tester,
      api,
      manual: true,
      snoozedUntil: _now.add(const Duration(days: 1)),
    );
    expect(find.text(offerTitle), findsOneWidget);
  });

  testWidgets('no sheet when the app re-locked during the check', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = await _run(tester, api, canPrompt: () => false);

    expect(find.text(offerTitle), findsNothing);
    // Not the user's choice, so it must not snooze either.
    expect(settings.updatePromptSnoozedUntil, isNull);
  });

  testWidgets('an already-downloaded update goes straight to Restart', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(
      info: updateInfo(
        availability: UpdateAvailability.updateAvailable,
        installStatus: InstallStatus.downloaded,
      ),
    );
    await _run(tester, api);

    expect(find.text(offerTitle), findsNothing);
    expect(find.text('Update downloaded'), findsOneWidget);
  });

  testWidgets('declining in Play snoozes too', (tester) async {
    final api = FakePlayUpdateApi(
      info: availableUpdate(),
      startResult: AppUpdateResult.userDeniedUpdate,
    );
    final settings = await _run(tester, api);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(find.text('Update downloaded'), findsNothing);
    expect(settings.updatePromptSnoozedUntil, isNotNull);
  });

  testWidgets('a failed download says so', (tester) async {
    final api = FakePlayUpdateApi(
      info: availableUpdate(),
      startResult: AppUpdateResult.inAppUpdateFailed,
    );
    await _run(tester, api);

    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    expect(
      find.text("The update couldn't download. Try again from Settings."),
      findsOneWidget,
    );
  });

  group('the manual check reports what it found', () {
    for (final (name, info, message) in [
      ('up to date', updateInfo(), "You're on the latest version"),
      (
        'unsupported',
        updateInfo(availability: UpdateAvailability.unknown),
        "Couldn't reach Google Play",
      ),
      (
        'in progress',
        updateInfo(installStatus: InstallStatus.downloading),
        'The update is downloading',
      ),
    ]) {
      testWidgets(name, (tester) async {
        await _run(tester, FakePlayUpdateApi(info: info), manual: true);
        expect(find.text(message), findsOneWidget);
      });
    }
  });

  testWidgets('the automatic check stays silent when there is nothing', (
    tester,
  ) async {
    await _run(tester, FakePlayUpdateApi());
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text(offerTitle), findsNothing);
  });

  testWidgets('a sideloaded install never asks Play', (tester) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    await _run(tester, api, fromPlay: false);

    expect(api.checkCalls, 0);
    expect(find.text(offerTitle), findsNothing);
  });

  testWidgets("a download Play never resolves doesn't block later checks", (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate())
      ..startCompleter = Completer<AppUpdateResult>();
    SharedPreferences.setMockInitialValues({'installed_from_play': true});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final service = AppUpdateService(
      api: api,
      settings: settings,
      now: () => _now,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUpdateServiceProvider.overrideWithValue(service)],
        child: MaterialApp(
          theme: AppTheme.theme,
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    onPressed: () => runAppUpdateCheck(context, ref),
                    child: const Text('automatic'),
                  ),
                  ElevatedButton(
                    onPressed: () =>
                        runAppUpdateCheck(context, ref, manual: true),
                    child: const Text('manual'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    // Start the automatic check and accept the update.
    await tester.tap(find.text('automatic'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();

    // The download never resolves. Set Play to report it's downloading.
    api.info = updateInfo(installStatus: InstallStatus.downloading);

    // A manual check should still work.
    await tester.tap(find.text('manual'));
    await tester.pumpAndSettle();
    expect(find.text('The update is downloading'), findsOneWidget);
  });

  testWidgets(
    "a download that resolves later doesn't clear another check's guard",
    (tester) async {
      final api = FakePlayUpdateApi(info: availableUpdate())
        ..startCompleter = Completer<AppUpdateResult>();
      SharedPreferences.setMockInitialValues({'installed_from_play': true});
      final settings = SettingsRepository(
        await SharedPreferences.getInstance(),
      );
      final service = AppUpdateService(
        api: api,
        settings: settings,
        now: () => _now,
      );
      BuildContext? savedContext;
      WidgetRef? savedRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appUpdateServiceProvider.overrideWithValue(service)],
          child: MaterialApp(
            theme: AppTheme.theme,
            home: Consumer(
              builder: (context, ref, _) {
                savedContext = context;
                savedRef = ref;
                return Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => runAppUpdateCheck(context, ref),
                      child: const Text('check'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );

      // Flow A: start automatic check, accept update (download pending).
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      // Flow B: run manual check while A is awaiting start. Play still reports
      // available, so B shows the sheet.
      runAppUpdateCheck(savedContext!, savedRef!, manual: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(offerTitle), findsOneWidget);

      // Flow A's download completes, hitting finally and clearing the guard.
      api.startCompleter!.complete(AppUpdateResult.success);
      await tester.pump();

      // Flow C: another check while B's sheet is open. On buggy code where
      // A's finally cleared B's guard, C can acquire the guard and stack a
      // second sheet.
      runAppUpdateCheck(savedContext!, savedRef!, manual: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(offerTitle), findsOneWidget); // Still just one.
    },
  );
}
