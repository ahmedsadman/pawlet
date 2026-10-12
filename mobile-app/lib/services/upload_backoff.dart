import 'dart:io' show HttpDate;

/// First wait after a failed upload to Pawlet's server; doubled per further
/// consecutive failure up to [kUploadBackoffCap].
const Duration kUploadBackoffBase = Duration(minutes: 15);

/// Longest wait after a failed upload. Callers ignore a retry time further
/// ahead than this (the clock moved back).
const Duration kUploadBackoffCap = Duration(hours: 6);

/// Shortest wait a 429's `Retry-After` can set.
const Duration kUploadRetryAfterMin = Duration(minutes: 1);

/// Retry pacing shared by the uploads to Pawlet's server.
class UploadBackoff {
  const UploadBackoff({
    required this.base,
    required this.cap,
    required this.retryAfterMin,
  });

  final Duration base;
  final Duration cap;
  final Duration retryAfterMin;

  /// [base] doubled per failure after the first, capped at [cap].
  Duration forFailures(int failures) {
    var delay = base;
    for (var i = 1; i < failures && delay < cap; i++) {
      delay *= 2;
    }
    return delay < cap ? delay : cap;
  }

  /// A 429's `Retry-After` [header] (delta-seconds or HTTP date) clamped to
  /// [retryAfterMin]..[cap], or null when missing or unparseable.
  Duration? retryAfter(String? header, int nowMs) {
    final value = header?.trim();
    if (value == null || value.isEmpty) return null;
    int ms;
    if (RegExp(r'^\d+$').hasMatch(value)) {
      // Capped before scaling to ms, which could overflow; too many digits
      // for an int is still "very long".
      final capSeconds = cap.inSeconds;
      final seconds = int.tryParse(value) ?? capSeconds;
      ms =
          (seconds < capSeconds ? seconds : capSeconds) *
          Duration.millisecondsPerSecond;
    } else {
      try {
        ms = HttpDate.parse(value).millisecondsSinceEpoch - nowMs;
      } catch (_) {
        return null;
      }
    }
    return Duration(
      milliseconds: ms.clamp(retryAfterMin.inMilliseconds, cap.inMilliseconds),
    );
  }
}

/// The pacing every upload to Pawlet's server uses.
const UploadBackoff kUploadBackoff = UploadBackoff(
  base: kUploadBackoffBase,
  cap: kUploadBackoffCap,
  retryAfterMin: kUploadRetryAfterMin,
);
