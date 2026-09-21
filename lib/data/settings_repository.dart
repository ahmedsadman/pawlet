import 'package:shared_preferences/shared_preferences.dart';

/// Local user settings backed by SharedPreferences. Meowni has no server, so
/// there is no webhook URL; instead it holds the normalized currency and the
/// finance-view preferences the UI persists. (LLM API key / model are added in
/// a later phase.)
class SettingsRepository {
  SettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const _kCurrency = 'currency';
  static const _kHideBalance = 'hide_balance';
  static const _kSummaryRange = 'summary_range';
  static const _kTxRange = 'tx_range';
  static const _kTxTypes = 'tx_types';
  static const _kTxSort = 'tx_sort';

  /// User's normalized reporting currency (all amounts are stored in it).
  String get currency => _prefs.getString(_kCurrency) ?? 'BDT';
  Future<void> setCurrency(String value) {
    final trimmed = value.trim().toUpperCase();
    return _prefs.setString(_kCurrency, trimmed.isEmpty ? 'BDT' : trimmed);
  }

  /// Masks monetary values across the Finance tab.
  bool get hideBalance => _prefs.getBool(_kHideBalance) ?? false;
  Future<void> setHideBalance(bool value) =>
      _prefs.setBool(_kHideBalance, value);

  String? get summaryRange => _prefs.getString(_kSummaryRange);
  Future<void> setSummaryRange(String key) =>
      _prefs.setString(_kSummaryRange, key);

  String? get txRange => _prefs.getString(_kTxRange);
  Future<void> setTxRange(String key) => _prefs.setString(_kTxRange, key);

  List<String> get txTypes {
    final raw = _prefs.getString(_kTxTypes);
    if (raw == null || raw.isEmpty) return const [];
    return raw.split(',');
  }

  Future<void> setTxTypes(List<String> values) =>
      _prefs.setString(_kTxTypes, values.join(','));

  String? get txSort => _prefs.getString(_kTxSort);
  Future<void> setTxSort(String key) => _prefs.setString(_kTxSort, key);
}
