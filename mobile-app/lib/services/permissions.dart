import 'package:permission_handler/permission_handler.dart';

/// Runtime permission requests for SMS reading.
class AppPermissions {
  const AppPermissions._();

  /// Requests SMS + notifications up front. Notifications are optional — denial
  /// only disables notifications, it does not block SMS capture.
  static Future<void> requestAll() async {
    await [Permission.sms, Permission.notification].request();
  }

  static Future<bool> hasSms() => Permission.sms.isGranted;

  /// Lets the app keep processing the queue while backgrounded.
  static Future<bool> requestBatteryExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }
}
