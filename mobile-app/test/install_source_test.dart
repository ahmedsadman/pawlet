import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/install_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pawlet/install');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void respond(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('the Play Store installer package reads as a Play install', () async {
    respond((call) async {
      expect(call.method, 'installerPackage');
      return 'com.android.vending';
    });
    expect(await InstallSource().isFromPlayStore(), isTrue);
  });

  test('another installer is not a Play install', () async {
    respond((_) async => 'com.google.android.packageinstaller');
    expect(await InstallSource().isFromPlayStore(), isFalse);
  });

  test('a null installer (adb sideload) is not a Play install', () async {
    respond((_) async => null);
    expect(await InstallSource().isFromPlayStore(), isFalse);
  });

  test('a platform error reads as not-from-Play', () async {
    // Safe default: showing the key input to a Play user is a cosmetic
    // mistake, hiding it from a sideload user leaves them with no LLM and
    // no way to enable one.
    respond((_) async => throw PlatformException(code: 'boom'));
    expect(await InstallSource().isFromPlayStore(), isFalse);
  });

  test('a missing channel reads as not-from-Play', () async {
    // Background isolates run a headless engine with no MainActivity, so the
    // channel is simply absent there.
    respond((_) async => throw MissingPluginException());
    expect(await InstallSource().isFromPlayStore(), isFalse);
  });
}
