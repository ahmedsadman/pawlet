import 'dart:async';

import 'package:in_app_update/in_app_update.dart';
import 'package:pawlet/services/app_update_service.dart';

/// Stands in for Google Play. Tests set [info] / [startResult] (or the error
/// fields) and read the call counters.
class FakePlayUpdateApi implements PlayUpdateApi {
  FakePlayUpdateApi({
    AppUpdateInfo? info,
    this.startResult = AppUpdateResult.success,
  }) : info = info ?? updateInfo();

  AppUpdateInfo info;
  Object? checkError;
  AppUpdateResult startResult;
  Object? startError;
  Object? completeError;

  /// Lets a test hold Play's answer to a check, e.g. to lock the app meanwhile.
  Completer<AppUpdateInfo>? checkCompleter;

  /// Lets a test model Play never resolving the download.
  Completer<AppUpdateResult>? startCompleter;

  int checkCalls = 0;
  int startCalls = 0;
  int completeCalls = 0;

  @override
  Future<AppUpdateInfo> checkForUpdate() async {
    checkCalls++;
    final error = checkError;
    if (error != null) throw error;
    final completer = checkCompleter;
    if (completer != null) return completer.future;
    return info;
  }

  @override
  Future<AppUpdateResult> startFlexibleUpdate() async {
    startCalls++;
    final error = startError;
    if (error != null) throw error;
    final completer = startCompleter;
    if (completer != null) return completer.future;
    return startResult;
  }

  @override
  Future<void> completeFlexibleUpdate() async {
    completeCalls++;
    final error = completeError;
    if (error != null) throw error;
  }
}

/// An [AppUpdateInfo] with only the fields the app reads made adjustable.
AppUpdateInfo updateInfo({
  UpdateAvailability availability = UpdateAvailability.updateNotAvailable,
  InstallStatus installStatus = InstallStatus.unknown,
  bool flexibleAllowed = true,
}) => AppUpdateInfo(
  updateAvailability: availability,
  immediateUpdateAllowed: false,
  immediateAllowedPreconditions: null,
  flexibleUpdateAllowed: flexibleAllowed,
  flexibleAllowedPreconditions: null,
  availableVersionCode: 42,
  installStatus: installStatus,
  packageName: 'com.pastabyte.pawlet',
  clientVersionStalenessDays: null,
  updatePriority: 0,
);

/// Shorthand for "Play has a new version and allows a flexible update".
AppUpdateInfo availableUpdate() =>
    updateInfo(availability: UpdateAvailability.updateAvailable);
