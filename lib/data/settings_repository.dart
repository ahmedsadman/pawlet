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
  static const _kResolveContacts = 'resolve_contacts';
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

  /// Attach a saved contact name to numeric senders (for display).
  bool get resolveContacts => _prefs.getBool(_kResolveContacts) ?? true;
  Future<void> setResolveContacts(bool value) =>
      _prefs.setBool(_kResolveContacts, value);

  /// Whether the user has seen the one-time "long-press to change type" hint.
  bool get txTypeHintSeen => _prefs.getBool(_kTxTypeHintSeen) ?? false;
  Future<void> setTxTypeHintSeen(bool value) =>
      _prefs.setBool(_kTxTypeHintSeen, value);

  /// Whether the user has seen the one-time History explainer banner.
  bool get historyHintSeen => _prefs.getBool(_kHistoryHintSeen) ?? false;
  Future<void> setHistoryHintSeen(bool value) =>
      _prefs.setBool(_kHistoryHintSeen, value);
}
