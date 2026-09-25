import 'package:permission_handler/permission_handler.dart';

/// Runtime permission requests for SMS reading and contact lookup.
class AppPermissions {
  const AppPermissions._();

  /// Requests SMS + contacts + notifications up front. Contacts and
  /// notifications are optional — denial only disables their respective
  /// feature, it does not block SMS capture.
  static Future<void> requestAll() async {
    await [
      Permission.sms,
      Permission.contacts,
      Permission.notification,
    ].request();
  }

  static Future<bool> hasSms() => Permission.sms.isGranted;

  static Future<bool> hasContacts() => Permission.contacts.isGranted;

  /// Lets the app keep processing the queue while backgrounded.
  static Future<bool> requestBatteryExemption() async {
    final status = await Permission.ignoreBatteryOptimizations.request();
    return status.isGranted;
  }
}
