import 'package:shared_preferences/shared_preferences.dart';

/// Local user settings backed by SharedPreferences. Pawlet has no server, so
/// there is no webhook URL; instead it holds the normalized currency and the
/// finance-view preferences the UI persists. (LLM API key / model are added in
/// a later phase.)
class SettingsRepository {
  SettingsRepository(this._prefs);

  final SharedPreferences _prefs;

  static const _kHideBalance = 'hide_balance';
  static const _kSummaryRange = 'summary_range';
  static const _kTxRange = 'tx_range';
  static const _kTxTypes = 'tx_types';
  static const _kTxSort = 'tx_sort';
  static const _kTxTypeHintSeen = 'tx_type_hint_seen';
  static const _kHistoryHintSeen = 'history_hint_seen';

  /// OpenRouter models tried in order (static ordered fallback in one request).
  /// All are structured-outputs-capable, so `response_format: json_schema` is
  /// honored; `provider.require_parameters` keeps each hop on a schema-capable
  /// provider. Strongest first (best extraction on the common case).
  static const List<String> defaultLlmModels = [
    'nvidia/nemotron-3-super-120b-a12b:free',
    'qwen/qwen3.8-27b:free',
    'nex-agi/nex-n2.5-pro:free',
  ];

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

  /// Whether the user has seen the one-time "long-press to change type" hint.
  bool get txTypeHintSeen => _prefs.getBool(_kTxTypeHintSeen) ?? false;
  Future<void> setTxTypeHintSeen(bool value) =>
      _prefs.setBool(_kTxTypeHintSeen, value);

  /// Whether the user has seen the one-time History explainer banner.
  bool get historyHintSeen => _prefs.getBool(_kHistoryHintSeen) ?? false;
  Future<void> setHistoryHintSeen(bool value) =>
      _prefs.setBool(_kHistoryHintSeen, value);

  /// Keys included in Backup & Restore, grouped by value type so [exportAll]
  /// and [importAll] round-trip them with the correct SharedPreferences
  /// getter/setter. Secrets (PIN, API key) live in SecureStore and are never
  /// backed up here.
  static const List<String> _backupStringKeys = [
    _kSummaryRange,
    _kTxRange,
    _kTxTypes,
    _kTxSort,
  ];
  static const List<String> _backupBoolKeys = [
    _kHideBalance,
    _kTxTypeHintSeen,
    _kHistoryHintSeen,
  ];

  /// Snapshot of user settings for a backup (only keys that are actually set).
  Map<String, Object?> exportAll() {
    final out = <String, Object?>{};
    for (final key in _backupStringKeys) {
      final value = _prefs.getString(key);
      if (value != null) out[key] = value;
    }
    for (final key in _backupBoolKeys) {
      if (_prefs.containsKey(key)) out[key] = _prefs.getBool(key);
    }
    return out;
  }

  /// Replaces all backup-managed settings with [data]. Keys absent from [data]
  /// are cleared, so a restore is a replace (not a merge); unknown keys and
  /// type mismatches are ignored for forward/backward compatibility.
  Future<void> importAll(Map<String, Object?> data) async {
    for (final key in [..._backupStringKeys, ..._backupBoolKeys]) {
      await _prefs.remove(key);
    }
    for (final entry in data.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_backupStringKeys.contains(key) && value is String) {
        await _prefs.setString(key, value);
      } else if (_backupBoolKeys.contains(key) && value is bool) {
        await _prefs.setBool(key, value);
      }
    }
  }
}
