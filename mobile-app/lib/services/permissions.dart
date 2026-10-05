import 'package:permission_handler/permission_handler.dart';

/// Runtime permission requests for SMS reading.
class AppPermissions {
  const AppPermissions._();

  /// SMS is a Play "restricted permission": never call this without showing
  /// the disclosure first. Go through `ensureSmsAccess` rather than calling it
  /// directly.
  static Future<void> requestSms() async {
    await Permission.sms.request();
  }

  /// Optional — denial only disables notifications, it does not block SMS
  /// capture, so this needs no disclosure.
  static Future<void> requestNotifications() async {
    await Permission.notification.request();
  }

  static Future<bool> hasSms() => Permission.sms.isGranted;

  /// Lets the app keep processing the queue while backgrounded.
  static Future<bool> requestBatteryExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }
}
