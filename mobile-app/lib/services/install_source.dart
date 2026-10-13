import 'package:flutter/services.dart';

/// Reads which store installed this app, over the `pawlet/install` channel.
///
/// A UI affordance only: it decides whether Settings offers the
/// bring-your-own-key input. It is never a security boundary — Pawlet's server
/// demands a Play Integrity verdict regardless of what the client claims here.
class InstallSource {
  InstallSource([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel('pawlet/install');

  final MethodChannel _channel;

  /// The Play Store's own package name, recorded as the installer for any app
  /// Play delivered.
  static const String playStorePackage = 'com.android.vending';

  /// False on any failure, which is the safe default: showing the key input to
  /// a Play user is cosmetic, but hiding it from a sideload user would leave
  /// them with no LLM and no way to enable one.
  Future<bool> isFromPlayStore() async {
    try {
      final installer = await _channel.invokeMethod<String>('installerPackage');
      return installer == playStorePackage;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
