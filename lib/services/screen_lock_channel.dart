import 'package:flutter/services.dart';

/// Bridges the native `meowni/security` channel. The Android side flips a flag
/// on `ACTION_SCREEN_OFF`; [consumeScreenOff] reads and clears it so the app can
/// re-lock only after the device was actually locked (not on app-switching).
class ScreenLockChannel {
  ScreenLockChannel([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('meowni/security');

  final MethodChannel _channel;

  Future<bool> consumeScreenOff() async {
    try {
      return await _channel.invokeMethod<bool>('consumeScreenOff') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
