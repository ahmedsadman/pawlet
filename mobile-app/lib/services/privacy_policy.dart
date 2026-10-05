import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

/// The hosted privacy policy. Google Play requires it to be reachable from
/// inside the app, not only from the Console listing.
class PrivacyPolicy {
  const PrivacyPolicy._();

  /// Source lives at `gh-pages/index.html`; `.github/workflows/pages.yml`
  /// deploys it. Update both together.
  static const url = 'https://ahmedsadman.github.io/pawlet/';

  /// Seam for widget tests, which have no browser and no plugin.
  @visibleForTesting
  static Future<bool> Function(Uri uri) launcher = _launch;

  @visibleForTesting
  static void resetLauncher() => launcher = _launch;

  /// Opens the policy in the system browser. False when nothing can handle it,
  /// so callers can surface a fallback instead of failing silently.
  static Future<bool> open() => launcher(Uri.parse(url));

  static Future<bool> _launch(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
