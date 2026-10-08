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

/// What a test needs from the pumped app.
class _Harness {
  _Harness(this.service, this.settings);

  final AppUpdateService service;
  final SettingsRepository settings;

  /// Captured from the page, for starting a check while a sheet covers the
  /// buttons.
  late BuildContext context;
  late WidgetRef ref;
}

/// Pumps a page with two buttons: 'check' runs the automatic check (gated by
/// [canPrompt], which defaults to always allowed) and 'manual' runs the
/// Settings check.
Future<_Harness> _pumpHarness(
  WidgetTester tester,
  FakePlayUpdateApi api, {
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
  final harness = _Harness(
    AppUpdateService(api: api, settings: settings, now: () => _now),
    settings,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [appUpdateServiceProvider.overrideWithValue(harness.service)],
      child: MaterialApp(
        theme: AppTheme.theme,
        home: Consumer(
          builder: (context, ref, _) {
            harness
              ..context = context
              ..ref = ref;
            return Scaffold(
              body: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: () => runAppUpdateCheck(
                        context,
                        ref,
                        canPrompt: canPrompt ?? () => true,
                      ),
                      child: const Text('check'),
                    ),
                    ElevatedButton(
                      onPressed: () =>
                          runAppUpdateCheck(context, ref, manual: true),
                      child: const Text('manual'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );
  return harness;
}

/// Pumps the harness, taps the automatic (or [manual]) check, and settles.
Future<_Harness> _run(
  WidgetTester tester,
  FakePlayUpdateApi api, {
  bool manual = false,
  bool fromPlay = true,
  DateTime? snoozedUntil,
  bool Function()? canPrompt,
}) async {
  final harness = await _pumpHarness(
    tester,
    api,
    fromPlay: fromPlay,
    snoozedUntil: snoozedUntil,
    canPrompt: canPrompt,
  );
  await tester.tap(find.text(manual ? 'manual' : 'check'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  const offerTitle = 'A new version is ready';

  // A tap that lands on a sheet's barrier instead of its target would let a
  // test pass without running the check it means to run.
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);

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

  testWidgets('the restart bar hides on its own', (tester) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    await _run(tester, api);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
    expect(find.text('Update downloaded'), findsOneWidget);

    await tester.pump(restartBarDuration);
    await tester.pumpAndSettle();
    expect(find.text('Update downloaded'), findsNothing);
  });

  testWidgets('Not now snoozes the automatic prompt for three days', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = (await _run(tester, api)).settings;

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
    final settings = (await _run(tester, api)).settings;

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

  testWidgets("an automatic check while locked doesn't ask Play", (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = (await _run(tester, api, canPrompt: () => false)).settings;

    expect(api.checkCalls, 0);
    expect(find.text(offerTitle), findsNothing);
    // Not the user's choice, so it must not snooze either.
    expect(settings.updatePromptSnoozedUntil, isNull);
  });

  testWidgets("a sheet blocked by a re-lock doesn't use up the hour's check", (
    tester,
  ) async {
    var unlocked = true;
    final api = FakePlayUpdateApi(info: availableUpdate())
      ..checkCompleter = Completer<AppUpdateInfo>();
    final harness = await _pumpHarness(tester, api, canPrompt: () => unlocked);

    // The app re-locks while Play is answering.
    await tester.tap(find.text('check'));
    await tester.pump();
    unlocked = false;
    api.checkCompleter!.complete(availableUpdate());
    await tester.pumpAndSettle();
    expect(find.text(offerTitle), findsNothing);
    expect(harness.settings.updatePromptSnoozedUntil, isNull);

    // Unlocked again within the hour: the offer still comes.
    unlocked = true;
    api.checkCompleter = null;
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(api.checkCalls, 2);
    expect(find.text(offerTitle), findsOneWidget);
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
    final settings = (await _run(tester, api)).settings;

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
        "Couldn't check for updates right now",
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
    await _pumpHarness(tester, api);

    // Start the automatic check and accept the update.
    await tester.tap(find.text('check'));
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
      final harness = await _pumpHarness(tester, api);

      // Flow A: start automatic check, accept update (download pending).
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      // Flow B: run manual check while A is awaiting start. Play still reports
      // available, so B shows the sheet.
      runAppUpdateCheck(harness.context, harness.ref, manual: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(offerTitle), findsOneWidget);

      // Flow A's download completes, hitting finally and clearing the guard.
      api.startCompleter!.complete(AppUpdateResult.success);
      await tester.pump();

      // Flow C: another check while B's sheet is open. On buggy code where
      // A's finally cleared B's guard, C can acquire the guard and stack a
      // second sheet.
      runAppUpdateCheck(harness.context, harness.ref, manual: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text(offerTitle), findsOneWidget); // Still just one.
    },
  );

  testWidgets('a second automatic check within the hour is throttled', (
    tester,
  ) async {
    // Up to date, so no sheet covers the button for the second tap.
    final api = FakePlayUpdateApi();
    await _pumpHarness(tester, api);

    // First automatic check calls Play.
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(api.checkCalls, 1);

    // Second automatic check within the hour is throttled.
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
    expect(api.checkCalls, 1); // Still 1, no second call.
  });

  testWidgets(
    'once the restart bar hides, an automatic check shows it again without '
    'calling Play',
    (tester) async {
      final api = FakePlayUpdateApi(
        info: updateInfo(
          availability: UpdateAvailability.updateAvailable,
          installStatus: InstallStatus.downloaded,
        ),
      );
      await _pumpHarness(tester, api);

      // First check discovers the download.
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(api.checkCalls, 1);
      expect(find.text('Update downloaded'), findsOneWidget);

      // Let the bar hide, so the next check has to bring it back.
      await tester.pump(restartBarDuration);
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsNothing);

      // Second automatic check shows the bar without calling Play again.
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(api.checkCalls, 1); // Still 1, no second call.
      expect(find.text('Update downloaded'), findsOneWidget);
    },
  );

  group('no restart bar over the lock screen', () {
    final downloaded = updateInfo(
      availability: UpdateAvailability.updateAvailable,
      installStatus: InstallStatus.downloaded,
    );

    testWidgets('for a download already known', (tester) async {
      var unlocked = false;
      final api = FakePlayUpdateApi(info: downloaded);
      final harness = await _pumpHarness(
        tester,
        api,
        canPrompt: () => unlocked,
      );
      await harness.service.check();

      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsNothing);
      expect(api.checkCalls, 1); // Only the check above.

      unlocked = true;
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsOneWidget);
      expect(api.checkCalls, 1);
    });

    testWidgets('for a download Play reports after the app re-locked', (
      tester,
    ) async {
      var unlocked = true;
      final api = FakePlayUpdateApi()
        ..checkCompleter = Completer<AppUpdateInfo>();
      await _pumpHarness(tester, api, canPrompt: () => unlocked);

      await tester.tap(find.text('check'));
      await tester.pump();
      unlocked = false;
      api.checkCompleter!.complete(downloaded);
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsNothing);

      unlocked = true;
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsOneWidget);
    });

    testWidgets('for a download that finishes after the app re-locked', (
      tester,
    ) async {
      var unlocked = true;
      final api = FakePlayUpdateApi(info: availableUpdate())
        ..startCompleter = Completer<AppUpdateResult>();
      await _pumpHarness(tester, api, canPrompt: () => unlocked);

      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();

      unlocked = false;
      api.startCompleter!.complete(AppUpdateResult.success);
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsNothing);

      unlocked = true;
      await tester.tap(find.text('check'));
      await tester.pumpAndSettle();
      expect(find.text('Update downloaded'), findsOneWidget);
    });
  });

  testWidgets('Not now on a manual check also writes the snooze', (
    tester,
  ) async {
    final api = FakePlayUpdateApi(info: availableUpdate());
    final settings = (await _run(tester, api, manual: true)).settings;

    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(settings.updatePromptSnoozedUntil, isNotNull);
  });
}
