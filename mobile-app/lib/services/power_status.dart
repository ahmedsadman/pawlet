import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'permissions.dart';

/// The battery state the prompt decides on, and the two ways out of it.
/// Failed reads resolve to "nothing to ask": exempt, and not restricted.
class PowerStatus {
  PowerStatus([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('pawlet/power');

  final MethodChannel _channel;

  /// Whether battery optimization is already off for Pawlet. A failed read
  /// counts as exempt: better to skip a prompt than to nag on a guess.
  Future<bool> isBatteryExempt() async {
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Whether battery usage is set to "Restricted" (API 28+; false below).
  Future<bool> isBackgroundRestricted() async {
    try {
      return await _channel.invokeMethod<bool>('isBackgroundRestricted') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Shows the system "stop optimizing battery usage?" dialog. Resolves true
  /// when the exemption was granted.
  Future<bool> requestExemption() => AppPermissions.requestBatteryExemption();

  /// Opens Pawlet's App info page, where battery usage can be set to
  /// Unrestricted.
  Future<bool> openSettings() => openAppSettings();
}
