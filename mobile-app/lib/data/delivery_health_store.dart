import 'package:shared_preferences/shared_preferences.dart';

/// Bookkeeping for the battery-optimization prompt: how far the phone inbox
/// has been checked for SMS the receiver missed, the misses found, and the
/// prompt's snooze. Install-scoped, so outside Backup & Restore. Written by the
/// UI isolate only, so no reload is needed.
class DeliveryHealthStore {
  DeliveryHealthStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kWatermark = 'missed_sms_watermark';
  static const _kLastScanAt = 'missed_sms_last_scan_at';
  static const _kMissedAt = 'missed_sms_at';
  static const _kPromptSnoozedUntil = 'battery_prompt_snoozed_until';

  /// Receipt time (epoch ms) up to which the inbox has been checked. Null until
  /// the SMS listener first starts; nothing received before it counts.
  int? get watermark => _prefs.getInt(_kWatermark);
  Future<void> setWatermark(int ms) => _prefs.setInt(_kWatermark, ms);

  /// Sets the watermark to [nowMs] unless one exists. Called on every listener
  /// start, so only the first one counts.
  Future<void> ensureWatermark(int nowMs) async {
    if (watermark != null) return;
    await setWatermark(nowMs);
  }

  /// When the last inbox scan ran (epoch ms).
  int? get lastScanAt => _prefs.getInt(_kLastScanAt);
  Future<void> setLastScanAt(int ms) => _prefs.setInt(_kLastScanAt, ms);

  /// Receipt times (epoch ms) of bank SMS the receiver missed.
  List<int> get missedAt => [
    for (final s in _prefs.getStringList(_kMissedAt) ?? const <String>[])
      ?int.tryParse(s),
  ];
  Future<void> setMissedAt(List<int> values) =>
      _prefs.setStringList(_kMissedAt, [for (final v in values) '$v']);

  /// The prompt stays quiet until this time (epoch ms).
  int? get promptSnoozedUntil => _prefs.getInt(_kPromptSnoozedUntil);
  Future<void> setPromptSnoozedUntil(int ms) =>
      _prefs.setInt(_kPromptSnoozedUntil, ms);

  /// Starts detection over from [nowMs]: the watermark moves to it and recorded
  /// misses are dropped. Used after a restore replaces `sms_records`, which would
  /// otherwise make messages captured before the restore read as missed.
  Future<void> restartFrom(int nowMs) async {
    await setWatermark(nowMs);
    await setMissedAt(const []);
  }
}
