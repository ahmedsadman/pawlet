import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/power_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('pawlet/power');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads the restricted flag from the platform', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isBackgroundRestricted');
      return true;
    });
    expect(await PowerStatus().isBackgroundRestricted(), isTrue);
  });

  test('a platform error reads as not restricted', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'boom'),
    );
    expect(await PowerStatus().isBackgroundRestricted(), isFalse);
  });

  test('a missing platform side reads as not restricted', () async {
    expect(await PowerStatus().isBackgroundRestricted(), isFalse);
  });

  test('an unreadable exemption status counts as exempt', () async {
    // No permission_handler platform side in unit tests: the read throws.
    expect(await PowerStatus().isBatteryExempt(), isTrue);
  });
}
