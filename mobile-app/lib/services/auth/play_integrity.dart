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
  /// token: API_NOT_AVAILABLE (-1), PLAY_STORE_NOT_FOUND (-2),
  /// PLAY_SERVICES_NOT_FOUND (-6). Network errors, throttling, and outdated
  /// Play components the user can update are all retried instead.
  static const Set<String> permanentErrorCodes = {'-1', '-2', '-6'};

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
      throw const IntegrityException('no_activity', permanent: false);
    }
    if (token == null || token.isEmpty) {
      throw const IntegrityException('empty_token', permanent: false);
    }
    return token;
  }
}
