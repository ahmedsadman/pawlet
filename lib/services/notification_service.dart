import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Posts a single, generic local notification summarising processing failures.
///
/// The plugin's default constructor returns a process-wide singleton, so [init]
/// can run independently in the UI and WorkManager isolates and both still
/// target the same native notification.
class NotificationService {
  NotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    SharedPreferences? prefs,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin(),
       // `_prefs` is private and this is a named param, so an initializing
       // formal (`this._prefs`) isn't allowed here.
       // ignore: prefer_initializing_formals
       _prefs = prefs;

  final FlutterLocalNotificationsPlugin _plugin;
  final SharedPreferences? _prefs;

  static const String _channelId = 'meowni_failures';
  static const String _channelName = 'Processing failures';
  static const String _channelDescription =
      'Alerts when SMS messages cannot be processed';

  static const int _failureNotificationId = 1;

  /// Prefix for the persisted per-id last-posted count.
  static const String _lastCountKeyPrefix = 'notif_last_count_';

  /// In-memory fallback used only when no [SharedPreferences] was injected
  /// (e.g. a unit test that doesn't care about persistence).
  final Map<int, int> _memoLastPosted = {};

  /// Last count posted per notification id. Reconcile runs after *every*
  /// processing pass (each pull-to-refresh, resume, incoming SMS, WorkManager
  /// tick), so without this guard an unchanged count would re-`show()` the same
  /// notification and re-alert every time. We only touch the notification when
  /// the count actually changes: a genuine increase still alerts, an unchanged
  /// count is a no-op, and dropping to zero cancels once.
  ///
  /// Persisted in [SharedPreferences] so the guard survives a process restart
  /// and is shared across the UI and WorkManager isolates (both open the same
  /// store); [_reconcile] reloads before reading so a write from the other
  /// isolate is seen.
  int? _readLastPosted(int id) {
    final prefs = _prefs;
    if (prefs == null) return _memoLastPosted[id];
    return prefs.getInt('$_lastCountKeyPrefix$id');
  }

  Future<void> _writeLastPosted(int id, int count) async {
    final prefs = _prefs;
    if (prefs == null) {
      _memoLastPosted[id] = count;
      return;
    }
    await prefs.setInt('$_lastCountKeyPrefix$id', count);
  }

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

  Future<void> _reconcile({
    required int id,
    required String title,
    required int count,
    required String Function(String noun) body,
  }) async {
    // Refresh from disk so a write by the other isolate (UI vs WorkManager) is
    // seen before we decide whether the count changed.
    await _prefs?.reload();
    final last = _readLastPosted(id);

    if (count <= 0) {
      if (last != 0) {
        await _plugin.cancel(id);
        await _writeLastPosted(id, 0);
      }
      return;
    }
    if (last == count) return; // unchanged — don't re-alert
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
    await _writeLastPosted(id, count);
  }
}
