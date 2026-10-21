/// What the battery-optimization prompt offers, if anything.
enum BatteryPromptVerdict {
  none,

  /// Battery optimization is on and the receiver has been missing bank SMS.
  requestExemption,

  /// Battery usage is set to "Restricted". The exemption dialog does not lift
  /// that (they are separate settings), so the way out is App info.
  openSettings,
}

/// When to offer the prompt. Pure, so the rules are tested without a device.
class BatteryPromptPolicy {
  const BatteryPromptPolicy._();

  /// How long a miss counts as evidence.
  static const Duration missWindow = Duration(days: 7);

  /// Misses inside [missWindow] needed before asking. One alone can be a
  /// one-off (an SMS that landed mid-update), not the OS holding Pawlet back.
  static const int missThreshold = 2;

  /// How long the prompt stays quiet once shown.
  static const Duration snooze = Duration(days: 3);

  static BatteryPromptVerdict decide({
    required bool exempt,
    required bool restricted,
    required List<int> missedAt,
    required int? snoozedUntil,
    required int now,
  }) {
    if (snoozedUntil != null && now < snoozedUntil) {
      return BatteryPromptVerdict.none;
    }
    if (restricted) return BatteryPromptVerdict.openSettings;
    if (exempt) return BatteryPromptVerdict.none;
    final cutoff = now - missWindow.inMilliseconds;
    final recent = missedAt.where((t) => t >= cutoff).length;
    return recent >= missThreshold
        ? BatteryPromptVerdict.requestExemption
        : BatteryPromptVerdict.none;
  }
}
