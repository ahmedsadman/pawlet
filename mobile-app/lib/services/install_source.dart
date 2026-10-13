import 'package:flutter/services.dart';

/// Reads how this app was installed, over the `pawlet/install` channel: which
/// store delivered it, and whether it runs on a Firebase Test Lab device.
///
/// Neither answer is a security boundary — Pawlet's server demands a Play
/// Integrity verdict regardless of what the client claims here.
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

  /// Whether this is a Firebase Test Lab device, as used by Play's pre-launch
  /// report. Those devices run every uploaded build and must not show up as
  /// installs. False on any failure: a real install that stops reporting
  /// costs more than one stray test device.
  Future<bool> isTestLab() async {
    try {
      return await _channel.invokeMethod<bool>('isTestLab') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
