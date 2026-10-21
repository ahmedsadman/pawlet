import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/services/battery_prompt_policy.dart';

void main() {
  final now = DateTime(2026, 10, 21, 12).millisecondsSinceEpoch;
  const day = 24 * 60 * 60 * 1000;

  BatteryPromptVerdict decide({
    bool exempt = false,
    bool restricted = false,
    List<int> missedAt = const [],
    int? snoozedUntil,
  }) => BatteryPromptPolicy.decide(
    exempt: exempt,
    restricted: restricted,
    missedAt: missedAt,
    snoozedUntil: snoozedUntil,
    now: now,
  );

  test('two recent misses while optimized asks for the exemption', () {
    expect(
      decide(missedAt: [now - day, now - 2 * day]),
      BatteryPromptVerdict.requestExemption,
    );
  });

  test('a single miss is not enough', () {
    expect(decide(missedAt: [now - day]), BatteryPromptVerdict.none);
  });

  test('misses older than the window do not count', () {
    expect(
      decide(missedAt: [now - day, now - 8 * day]),
      BatteryPromptVerdict.none,
    );
  });

  test('a miss exactly at the window edge counts', () {
    expect(
      decide(missedAt: [now - day, now - 7 * day]),
      BatteryPromptVerdict.requestExemption,
    );
  });

  test('an exempt app is never asked, however many misses', () {
    expect(
      decide(exempt: true, missedAt: [now - day, now - day, now - day]),
      BatteryPromptVerdict.none,
    );
  });

  test('restricted offers settings with no misses at all', () {
    expect(decide(restricted: true), BatteryPromptVerdict.openSettings);
  });

  test('restricted offers settings even when exempt', () {
    expect(
      decide(restricted: true, exempt: true),
      BatteryPromptVerdict.openSettings,
    );
  });

  test('an active snooze silences every verdict', () {
    expect(
      decide(restricted: true, snoozedUntil: now + 1),
      BatteryPromptVerdict.none,
    );
    expect(
      decide(missedAt: [now - day, now - day], snoozedUntil: now + 1),
      BatteryPromptVerdict.none,
    );
  });

  test('an expired snooze no longer silences', () {
    expect(
      decide(restricted: true, snoozedUntil: now),
      BatteryPromptVerdict.openSettings,
    );
  });
}
