import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';

import '../data/settings_repository.dart';

/// What Play reports for this install, reduced to what the UI acts on.
enum UpdateStatus {
  /// Not a Play install, Play unreachable, or Play won't allow a flexible
  /// update right now (for example, low storage).
  unsupported,
  upToDate,
  available,

  /// A flexible download started earlier is still running.
  inProgress,

  /// Downloaded and waiting for [AppUpdateService.restart].
  downloaded,
}

/// How a started flexible update ended.
enum UpdateStartResult { downloaded, declined, failed }

/// Seam over the static [InAppUpdate] API, so tests can stand in for Play.
abstract interface class PlayUpdateApi {
  Future<AppUpdateInfo> checkForUpdate();
  Future<AppUpdateResult> startFlexibleUpdate();
  Future<void> completeFlexibleUpdate();
}

class InAppUpdatePlayApi implements PlayUpdateApi {
  const InAppUpdatePlayApi();

  @override
  Future<AppUpdateInfo> checkForUpdate() => InAppUpdate.checkForUpdate();

  @override
  Future<AppUpdateResult> startFlexibleUpdate() =>
      InAppUpdate.startFlexibleUpdate();

  @override
  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();
}

/// Play in-app updates, flexible flow only: the user keeps using the app while
/// Play downloads, then restarts to install.
///
/// UI isolate only. The plugin needs a foreground activity, which the
/// WorkManager and background-SMS isolates do not have.
class AppUpdateService {
  AppUpdateService({
    required this._api,
    required this._settings,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long "Not now" keeps the automatic prompt quiet.
  static const snoozeFor = Duration(days: 3);

  final PlayUpdateApi _api;
  final SettingsRepository _settings;
  final DateTime Function() _now;

  Future<UpdateStatus> check() async {
    // Play rejects requests from installs it did not deliver (sideloads,
    // debug builds), so don't ask.
    if (!_settings.installedFromPlay) return UpdateStatus.unsupported;
    try {
      return statusOf(await _api.checkForUpdate());
    } catch (_) {
      // Play Services missing, offline, or the Play Store app too old.
      return UpdateStatus.unsupported;
    }
  }

  bool get isSnoozed {
    final until = _settings.updatePromptSnoozedUntil;
    return until != null && _now().isBefore(until);
  }

  Future<void> snooze() =>
      _settings.setUpdatePromptSnoozedUntil(_now().add(snoozeFor));

  /// Shows Play's own confirmation, then downloads. Completes only when the
  /// download finishes, the user declines, or it fails, so this can take
  /// minutes.
  Future<UpdateStartResult> start() async {
    try {
      return switch (await _api.startFlexibleUpdate()) {
        AppUpdateResult.success => UpdateStartResult.downloaded,
        AppUpdateResult.userDeniedUpdate => UpdateStartResult.declined,
        AppUpdateResult.inAppUpdateFailed => UpdateStartResult.failed,
      };
    } catch (_) {
      // The plugin rethrows install errors (e.g. an interrupted download) raw.
      return UpdateStartResult.failed;
    }
  }

  /// Installs the downloaded update. Play restarts the app, so nothing after
  /// this call runs.
  Future<void> restart() => _api.completeFlexibleUpdate();
}

@visibleForTesting
UpdateStatus statusOf(AppUpdateInfo info) {
  // Install status first, so a running or finished download wins whatever
  // availability Play reports alongside it.
  switch (info.installStatus) {
    case InstallStatus.downloaded:
      return UpdateStatus.downloaded;
    case InstallStatus.pending ||
        InstallStatus.downloading ||
        InstallStatus.installing:
      return UpdateStatus.inProgress;
    default:
      break;
  }
  return switch (info.updateAvailability) {
    UpdateAvailability.updateAvailable =>
      info.flexibleUpdateAllowed
          ? UpdateStatus.available
          : UpdateStatus.unsupported,
    UpdateAvailability.updateNotAvailable => UpdateStatus.upToDate,
    UpdateAvailability.developerTriggeredUpdateInProgress =>
      UpdateStatus.inProgress,
    UpdateAvailability.unknown => UpdateStatus.unsupported,
  };
}
