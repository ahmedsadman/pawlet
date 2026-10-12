import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/upload_backoff.dart';

void main() {
  const pacing = UploadBackoff(
    base: Duration(minutes: 15),
    cap: Duration(hours: 6),
    retryAfterMin: Duration(minutes: 1),
  );

  test('doubles per failure after the first, capped', () {
    expect(pacing.forFailures(1), const Duration(minutes: 15));
    expect(pacing.forFailures(2), const Duration(minutes: 30));
    expect(pacing.forFailures(5), const Duration(hours: 4));
    expect(pacing.forFailures(6), const Duration(hours: 6));
    expect(pacing.forFailures(60), const Duration(hours: 6));
  });

  test('parses Retry-After seconds and dates, clamped', () {
    final now = DateTime.utc(2026, 10, 13).millisecondsSinceEpoch;
    expect(pacing.retryAfter('120', now), const Duration(minutes: 2));
    expect(pacing.retryAfter('5', now), const Duration(minutes: 1));
    expect(
      pacing.retryAfter('999999999999999999999', now),
      const Duration(hours: 6),
    );
    final date = HttpDate.format(DateTime.utc(2026, 10, 13, 0, 10));
    expect(pacing.retryAfter(date, now), const Duration(minutes: 10));
    expect(pacing.retryAfter(null, now), isNull);
    expect(pacing.retryAfter('soon', now), isNull);
  });
}
