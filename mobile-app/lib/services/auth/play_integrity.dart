import 'package:flutter/services.dart';

import '../../config/build_config.dart';

/// Play Integrity could not produce a token. [permanent] means this device can
/// never produce one (no Play Store or Play Services at all); anything else is
/// worth retrying.
class IntegrityException implements Exception {
  const IntegrityException(this.code, {required this.permanent});

  /// The `StandardIntegrityErrorCode` as a string, or a local marker.
  final String code;
  final bool permanent;

  @override
  String toString() => 'IntegrityException($code, permanent=$permanent)';
}

/// Mints Play Integrity standard-request tokens over the `pawlet/integrity`
/// channel served by MainActivity.
class PlayIntegrity {
  PlayIntegrity({
    MethodChannel? channel,
    this.cloudProjectNumber = BuildConfig.playCloudProjectNumber,
  }) : _channel = channel ?? const MethodChannel('pawlet/integrity');

  final MethodChannel _channel;
  final String cloudProjectNumber;

  /// `StandardIntegrityErrorCode` values meaning the device can never mint a
  /// token: PLAY_STORE_NOT_FOUND (-2), PLAY_SERVICES_NOT_FOUND (-6). Network
  /// errors, throttling, and outdated Play components the user can update are
  /// retried. API_NOT_AVAILABLE (-1) is also transient because it can mean the
  /// API is not enabled in the Cloud/Play Console or the Play Store is too old
  /// (a misconfiguration must not mark every install ineligible).
  static const Set<String> permanentErrorCodes = {'-2', '-6'};

  /// Code for "nothing serves the channel": a background isolate, which has no
  /// MainActivity. Nothing will serve it for the rest of that isolate's life.
  static const String noActivity = 'no_activity';

  /// Throws [IntegrityException] [noActivity] when nothing serves the channel.
  /// One local platform-channel hop, so a caller can learn it before spending
  /// a server challenge on a token it cannot mint.
  Future<void> ensureAvailable() async {
    try {
      await _channel.invokeMethod<void>('ping');
    } on MissingPluginException {
      throw const IntegrityException(noActivity, permanent: false);
    }
  }

  /// A token bound to [requestHash], which the server recomputes and compares.
  Future<String> requestToken(String requestHash) async {
    final String? token;
    try {
      token = await _channel.invokeMethod<String>('requestToken', {
        'cloudProjectNumber': cloudProjectNumber,
        'requestHash': requestHash,
      });
    } on PlatformException catch (e) {
      throw IntegrityException(
        e.code,
        permanent: permanentErrorCodes.contains(e.code),
      );
    } on MissingPluginException {
      // Background isolates have no MainActivity, so nothing serves the
      // channel. Not the device's fault: the foreground will retry.
      throw const IntegrityException(noActivity, permanent: false);
    }
    if (token == null || token.isEmpty) {
      throw const IntegrityException('empty_token', permanent: false);
    }
    return token;
  }
}
