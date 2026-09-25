import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/notification_service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockPlugin extends Mock implements FlutterLocalNotificationsPlugin {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _MockPlugin plugin;
  late NotificationService service;

  setUp(() {
    plugin = _MockPlugin();
    when(
      () => plugin.show(any(), any(), any(), any()),
    ).thenAnswer((_) async {});
    when(() => plugin.cancel(any())).thenAnswer((_) async {});
    service = NotificationService(plugin: plugin);
  });

  test(
    'does not re-post the failure notification when the count is unchanged',
    () async {
      await service.reconcileFailures(9);
      await service.reconcileFailures(9);
      await service.reconcileFailures(9);

      verify(() => plugin.show(1, any(), any(), any())).called(1);
    },
  );

  test('re-posts when the failure count actually changes', () async {
    await service.reconcileFailures(9);
    await service.reconcileFailures(12);

    verify(() => plugin.show(1, any(), any(), any())).called(2);
  });

  test('cancels the notification when the count drops to zero', () async {
    await service.reconcileFailures(9);
    await service.reconcileFailures(0);

    verify(() => plugin.cancel(1)).called(1);
  });

  test(
    'does not re-post after a restart when the persisted count is unchanged',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();

      final before = NotificationService(plugin: plugin, prefs: prefs);
      await before.reconcileFailures(9);

      // A fresh instance on the same backing store simulates a process restart
      // (or a second isolate). The persisted count must suppress the re-post.
      final after = NotificationService(plugin: plugin, prefs: prefs);
      await after.reconcileFailures(9);

      verify(() => plugin.show(1, any(), any(), any())).called(1);
    },
  );
}
