import 'package:package_info_plus/package_info_plus.dart';

/// This build's Android versionCode (`package_info_plus` `buildNumber`).
///
/// Null when the plugin fails or the value is not a positive integer: callers
/// skip work that needs it rather than file it under a wrong version. The
/// plugin caches its own answer, so repeated calls are cheap.
Future<int?> readAppVersionCode() async {
  try {
    final code = int.tryParse((await PackageInfo.fromPlatform()).buildNumber);
    return code != null && code > 0 ? code : null;
  } catch (_) {
    return null;
  }
}
