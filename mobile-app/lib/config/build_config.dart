/// Compile-time configuration supplied through `--dart-define`.
///
/// Every value is a `String.fromEnvironment` constant, so it is baked into the
/// binary and reads identically from every isolate — no plumbing, and no risk
/// of the UI isolate and a background isolate disagreeing.
class BuildConfig {
  const BuildConfig._();

  /// Base URL of Pawlet's proxy server, e.g. `https://pawlet.muhib.me`.
  /// Empty when the build was never pointed at a server, which forces every
  /// install onto a personal key or onto the on-device model alone.
  static const String apiBase = String.fromEnvironment('PAWLET_API_BASE');

  static bool get apiBaseConfigured => apiBase.isNotEmpty;
}
