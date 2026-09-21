import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Posts a single, generic local notification summarising processing failures.
///
/// The plugin's default constructor returns a process-wide singleton, so [init]
/// can run independently in the UI and WorkManager isolates and both still
/// target the same native notification.
class NotificationService {
  NotificationService({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  static const String _channelId = 'meowni_failures';
  static const String _channelName = 'Processing failures';
  static const String _channelDescription =
      'Alerts when SMS messages cannot be processed';

  static const int _failureNotificationId = 1;
  static const int _retryingNotificationId = 2;

  Future<void> init() async {
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings);
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDescription,
            importance: Importance.defaultImportance,
          ),
        );
  }

  /// Shows the terminal-failure notification when [count] > 0, cancels it at 0.
  Future<void> reconcileFailures(int count) => _reconcile(
    id: _failureNotificationId,
    title: 'Processing failed',
    count: count,
    body: (noun) => "$count $noun couldn't be processed",
  );

  /// Shows an early alert when [count] > 0 messages are being retried.
  Future<void> reconcileRetrying(int count) => _reconcile(
    id: _retryingNotificationId,
    title: 'Processing delayed',
    count: count,
    body: (noun) => "$count $noun couldn't be processed yet and are being retried",
  );

  Future<void> _reconcile({
    required int id,
    required String title,
    required int count,
    required String Function(String noun) body,
  }) async {
    if (count <= 0) {
      await _plugin.cancel(id);
      return;
    }
    final noun = count == 1 ? 'message' : 'messages';
    await _plugin.show(
      id,
      title,
      body(noun),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
    );
  }
}
