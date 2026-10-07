/// Compile-time configuration supplied through `--dart-define`.
///
/// Every value is a `String.fromEnvironment` constant, so it is baked into the
/// binary and reads identically from every isolate — no plumbing, and no risk
/// of the UI isolate and a background isolate disagreeing.
class BuildConfig {
  const BuildConfig._();

  /// Base URL of Pawlet's proxy server, e.g. `https://pawlet.muhib.me`.
  /// Empty when the build was never pointed at a server: no prompt bundle is
  /// fetched and the proxy is unreachable.
  static const String apiBase = String.fromEnvironment('PAWLET_API_BASE');

  /// Google Cloud project number linked to the app in Play Console. Play
  /// Integrity mints tokens against it. Not a secret.
  static const String playCloudProjectNumber = String.fromEnvironment(
    'PLAY_CLOUD_PROJECT_NUMBER',
  );

  static bool get apiBaseConfigured => apiBase.isNotEmpty;

  /// Whether this build can use the proxy at all: it needs the server to talk
  /// to and the Cloud project to attest against. A debug build carrying only
  /// [apiBase] (for the prompt bundle) must not count.
  static bool get proxyConfigured =>
      apiBaseConfigured && playCloudProjectNumber.isNotEmpty;
}
