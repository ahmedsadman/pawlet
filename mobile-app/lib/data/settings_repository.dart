import 'package:shared_preferences/shared_preferences.dart';

/// Local user settings backed by SharedPreferences: the finance-view
/// preferences the UI persists, plus two install-scoped flags the LLM mode is
/// resolved from. Secrets live in [SecureStore], never here.
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
  static const _kBulkImportOffered = 'bulk_import_offered';
  static const _kInstalledFromPlay = 'installed_from_play';
  static const _kAttestationIneligible = 'attestation_ineligible';
  static const _kAttestationIneligibleSince = 'attestation_ineligible_since';
  static const _kLastSeenBuild = 'last_seen_build';
  static const _kUpdatePromptSnoozedUntil = 'update_prompt_snoozed_until';

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

  /// Whether the one-time "import your existing messages" offer has been shown.
  ///
  /// Deliberately outside Backup & Restore (see [_backupBoolKeys]): it is
  /// onboarding state for *this* install, so restoring a backup onto a fresh
  /// device should still offer the import there.
  bool get bulkImportOffered => _prefs.getBool(_kBulkImportOffered) ?? false;
  Future<void> setBulkImportOffered(bool value) =>
      _prefs.setBool(_kBulkImportOffered, value);

  /// Cached install source. The platform channel that reads it is served by
  /// MainActivity, which does not exist in the WorkManager and background-SMS
  /// isolates — they would always see "not from Play" and resolve a different
  /// mode from the UI isolate. The UI isolate refreshes this on every launch
  /// and background isolates read the cache.
  ///
  /// Deliberately outside Backup & Restore: it describes how THIS install was
  /// delivered, so restoring onto another phone must not import it.
  bool get installedFromPlay => _prefs.getBool(_kInstalledFromPlay) ?? false;
  Future<void> setInstalledFromPlay(bool value) =>
      _prefs.setBool(_kInstalledFromPlay, value);

  /// Until when the automatic in-app update prompt stays quiet after the user
  /// says "Not now". Settings → Check for updates ignores it.
  ///
  /// Install-scoped (it is about this install's Play state), so outside
  /// Backup & Restore.
  DateTime? get updatePromptSnoozedUntil {
    final ms = _prefs.getInt(_kUpdatePromptSnoozedUntil);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setUpdatePromptSnoozedUntil(DateTime until) =>
      _prefs.setInt(_kUpdatePromptSnoozedUntil, until.millisecondsSinceEpoch);

  /// Set once Pawlet's server (or Play itself) rejects this install's
  /// attestation, which means the proxy will not work on this device. Reveals
  /// the bring-your-own-key input so the user is not left with no LLM and no
  /// way to enable one. Install-scoped, so outside Backup & Restore.
  ///
  /// Not permanent: [expireAttestationIneligible] clears it on app update or
  /// after [attestationRetryAfter], so a transient Play Services fault heals.
  bool get attestationIneligible =>
      _prefs.getBool(_kAttestationIneligible) ?? false;

  DateTime? get attestationIneligibleSince {
    final ms = _prefs.getInt(_kAttestationIneligibleSince);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setAttestationIneligible(bool value, {DateTime? now}) async {
    await _prefs.setBool(_kAttestationIneligible, value);
    if (value) {
      await _prefs.setInt(
        _kAttestationIneligibleSince,
        (now ?? DateTime.now()).millisecondsSinceEpoch,
      );
    } else {
      await _prefs.remove(_kAttestationIneligibleSince);
    }
  }

  /// How long an ineligible install waits before attestation is tried again.
  static const Duration attestationRetryAfter = Duration(days: 7);

  /// Run once per launch, from the UI isolate, before providers read the flag.
  /// Records [build] and clears the flag when the app was updated since the
  /// last launch or the flag is older than [attestationRetryAfter]. Returns
  /// whether it cleared.
  Future<bool> expireAttestationIneligible({
    required String build,
    required DateTime now,
  }) async {
    final previousBuild = _prefs.getString(_kLastSeenBuild);
    await _prefs.setString(_kLastSeenBuild, build);
    if (!attestationIneligible) return false;

    final since = attestationIneligibleSince;
    final updated = previousBuild != null && previousBuild != build;
    final expired =
        since == null || now.difference(since) >= attestationRetryAfter;
    if (!updated && !expired) return false;

    await setAttestationIneligible(false);
    return true;
  }

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
