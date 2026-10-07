import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/auth/play_integrity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('pawlet/integrity');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void respond(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  PlayIntegrity integrity() => PlayIntegrity(cloudProjectNumber: '42');

  test('passes the project number and hash, returns the token', () async {
    respond((call) async {
      expect(call.method, 'requestToken');
      expect(call.arguments, {'cloudProjectNumber': '42', 'requestHash': 'h'});
      return 'tok';
    });
    expect(await integrity().requestToken('h'), 'tok');
  });

  test('Play Services missing is permanent', () async {
    respond((_) async => throw PlatformException(code: '-6'));
    await expectLater(
      integrity().requestToken('h'),
      throwsA(
        isA<IntegrityException>().having((e) => e.permanent, 'permanent', true),
      ),
    );
  });

  test('a network error is transient', () async {
    respond((_) async => throw PlatformException(code: '-3'));
    await expectLater(
      integrity().requestToken('h'),
      throwsA(
        isA<IntegrityException>().having(
          (e) => e.permanent,
          'permanent',
          false,
        ),
      ),
    );
  });

  test('no handler (a background isolate) is transient', () async {
    // No mock handler registered: the call raises MissingPluginException.
    await expectLater(
      integrity().requestToken('h'),
      throwsA(
        isA<IntegrityException>().having(
          (e) => e.permanent,
          'permanent',
          false,
        ),
      ),
    );
  });

  test('an empty token is transient', () async {
    respond((_) async => '');
    await expectLater(
      integrity().requestToken('h'),
      throwsA(isA<IntegrityException>()),
    );
  });
}
