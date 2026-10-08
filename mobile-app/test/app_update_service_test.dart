import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:pawlet/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/play_update_fakes.dart';

void main() {
  final now = DateTime(2026, 10, 9, 12);

  Future<(AppUpdateService, FakePlayUpdateApi, SettingsRepository)> make({
    bool fromPlay = true,
    AppUpdateInfo? info,
    AppUpdateResult startResult = AppUpdateResult.success,
    DateTime Function()? now,
  }) async {
    SharedPreferences.setMockInitialValues({'installed_from_play': fromPlay});
    final settings = SettingsRepository(await SharedPreferences.getInstance());
    final api = FakePlayUpdateApi(info: info, startResult: startResult);
    final service = AppUpdateService(
      api: api,
      settings: settings,
      now: now ?? (() => DateTime(2026, 10, 9, 12)),
    );
    return (service, api, settings);
  }

  group('statusOf', () {
    test('a finished download wins over availability', () {
      expect(
        statusOf(
          updateInfo(
            availability: UpdateAvailability.updateAvailable,
            installStatus: InstallStatus.downloaded,
          ),
        ),
        UpdateStatus.downloaded,
      );
    });

    test('a running download reads as in progress', () {
      for (final s in [
        InstallStatus.pending,
        InstallStatus.downloading,
        InstallStatus.installing,
      ]) {
        expect(
          statusOf(
            updateInfo(
              availability: UpdateAvailability.updateAvailable,
              installStatus: s,
            ),
          ),
          UpdateStatus.inProgress,
          reason: '$s',
        );
      }
    });

    test('an available update needs Play to allow the flexible flow', () {
      expect(statusOf(availableUpdate()), UpdateStatus.available);
      // e.g. not enough free storage for a background download.
      expect(
        statusOf(
          updateInfo(
            availability: UpdateAvailability.updateAvailable,
            flexibleAllowed: false,
          ),
        ),
        UpdateStatus.unsupported,
      );
    });

    test('the remaining availability values', () {
      expect(statusOf(updateInfo()), UpdateStatus.upToDate);
      expect(
        statusOf(
          updateInfo(
            availability: UpdateAvailability.developerTriggeredUpdateInProgress,
          ),
        ),
        UpdateStatus.inProgress,
      );
      expect(
        statusOf(updateInfo(availability: UpdateAvailability.unknown)),
        UpdateStatus.unsupported,
      );
    });

    test('failed and canceled fall through to availability for retry', () {
      for (final s in [InstallStatus.failed, InstallStatus.canceled]) {
        expect(
          statusOf(
            updateInfo(
              availability: UpdateAvailability.updateAvailable,
              installStatus: s,
            ),
          ),
          UpdateStatus.available,
          reason: '$s',
        );
      }
    });
  });

  group('check', () {
    test('a non-Play install never asks Play', () async {
      final (service, api, _) = await make(fromPlay: false);
      expect(await service.check(), UpdateStatus.unsupported);
      expect(api.checkCalls, 0);
    });

    test('maps what Play reports', () async {
      final (service, _, _) = await make(info: availableUpdate());
      expect(await service.check(), UpdateStatus.available);
    });

    test('a Play error reads as unsupported', () async {
      final (service, api, _) = await make();
      api.checkError = PlatformException(code: 'ERROR_APP_NOT_OWNED');
      expect(await service.check(), UpdateStatus.unsupported);
    });
  });

  group('snooze', () {
    test('lasts three days from now', () async {
      final (service, _, settings) = await make();
      expect(service.isSnoozed, isFalse);

      await service.snooze();

      expect(
        settings.updatePromptSnoozedUntil,
        now.add(const Duration(days: 3)),
      );
      expect(service.isSnoozed, isTrue);
    });

    test('ends once its time has passed', () async {
      final (service, _, settings) = await make();
      await settings.setUpdatePromptSnoozedUntil(now);
      expect(service.isSnoozed, isFalse);
    });
  });

  group('start', () {
    test('maps each plugin result', () async {
      for (final (result, expected) in [
        (AppUpdateResult.success, UpdateStartResult.downloaded),
        (AppUpdateResult.userDeniedUpdate, UpdateStartResult.declined),
        (AppUpdateResult.inAppUpdateFailed, UpdateStartResult.failed),
      ]) {
        final (service, _, _) = await make(startResult: result);
        expect(await service.start(), expected, reason: '$result');
      }
    });

    test('a raw install error reads as failed', () async {
      final (service, api, _) = await make();
      api.startError = PlatformException(code: 'Error during installation');
      expect(await service.start(), UpdateStartResult.failed);
    });
  });

  group('restart', () {
    test('completes the flexible update', () async {
      final (service, api, _) = await make();
      await service.restart();
      expect(api.completeCalls, 1);
    });

    test('swallows errors from the plugin', () async {
      final (service, api, _) = await make();
      api.completeError = PlatformException(code: 'REQUIRE_CHECK_FOR_UPDATE');
      await service.restart(); // Should not throw.
      expect(api.completeCalls, 1);
    });
  });

  group('takeAutomaticCheck', () {
    test('allows the first automatic check', () async {
      final (service, _, _) = await make();
      expect(service.takeAutomaticCheck(), isTrue);
    });

    test('throttles a second check within the hour', () async {
      final (service, _, _) = await make();
      service.takeAutomaticCheck(); // First check.
      expect(service.takeAutomaticCheck(), isFalse);
    });

    test('allows a check after an hour has passed', () async {
      var now = DateTime(2026, 10, 9, 12);
      final (service, _, _) = await make(now: () => now);
      service.takeAutomaticCheck(); // First check at 12:00.
      now = now.add(const Duration(hours: 1)); // Advance to 13:00.
      expect(service.takeAutomaticCheck(), isTrue);
    });
  });

  group('isDownloaded', () {
    test('is set when check() reports downloaded', () async {
      final (service, api, _) = await make();
      api.info = updateInfo(
        availability: UpdateAvailability.updateAvailable,
        installStatus: InstallStatus.downloaded,
      );
      expect(service.isDownloaded, isFalse);
      await service.check();
      expect(service.isDownloaded, isTrue);
    });

    test('is set when start() completes with downloaded', () async {
      final (service, api, _) = await make();
      api.info = availableUpdate();
      api.startResult = AppUpdateResult.success;
      expect(service.isDownloaded, isFalse);
      await service.start();
      expect(service.isDownloaded, isTrue);
    });
  });
}
