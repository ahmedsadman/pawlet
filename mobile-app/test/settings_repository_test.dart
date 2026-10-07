import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SettingsRepository> repo([Map<String, Object> seed = const {}]) async {
    SharedPreferences.setMockInitialValues(seed);
    return SettingsRepository(await SharedPreferences.getInstance());
  }

  test('txTypeHintSeen defaults false and persists', () async {
    final r = await repo();
    expect(r.txTypeHintSeen, isFalse);
    await r.setTxTypeHintSeen(true);
    expect(r.txTypeHintSeen, isTrue);
  });

  test('historyHintSeen defaults false and persists', () async {
    final r = await repo();
    expect(r.historyHintSeen, isFalse);
    await r.setHistoryHintSeen(true);
    expect(r.historyHintSeen, isTrue);
  });

  test('defaultLlmModels lists the SO fallback chain, strongest first', () {
    expect(SettingsRepository.defaultLlmModels, const [
      'nvidia/nemotron-3-super-120b-a12b:free',
      'qwen/qwen3.8-27b:free',
      'nex-agi/nex-n2.5-pro:free',
    ]);
  });

  test('exportAll captures only set keys', () async {
    final r = await repo({'hide_balance': true});
    final snap = r.exportAll();
    expect(snap['hide_balance'], true);
    // history_hint_seen was never written, so it is absent from the snapshot.
    expect(snap.containsKey('history_hint_seen'), isFalse);
  });

  test('importAll restores a snapshot', () async {
    final r = await repo({'hide_balance': true, 'tx_sort': 'amount'});
    final snap = r.exportAll();
    await r.setHideBalance(false);
    await r.setTxSort('date');
    await r.importAll(snap);
    expect(r.hideBalance, isTrue);
    expect(r.txSort, 'amount');
  });

  test('importAll clears keys missing from the snapshot (replace)', () async {
    final r = await repo({'history_hint_seen': true});
    await r.importAll(const {}); // empty snapshot
    expect(r.historyHintSeen, isFalse); // reset to its default
  });

  test('bulkImportOffered defaults false and persists', () async {
    final r = await repo();
    expect(r.bulkImportOffered, isFalse);
    await r.setBulkImportOffered(true);
    expect(r.bulkImportOffered, isTrue);
  });

  test('bulkImportOffered is install-local, not part of a backup', () async {
    final r = await repo();
    await r.setBulkImportOffered(true);
    expect(r.exportAll().containsKey('bulk_import_offered'), isFalse);

    // And a restore must not clear it either — it is not a managed key.
    await r.importAll(const {});
    expect(r.bulkImportOffered, isTrue);
  });

  group('install-scoped LLM flags', () {
    test('both default to false', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository(await SharedPreferences.getInstance());
      expect(repo.installedFromPlay, isFalse);
      expect(repo.attestationIneligible, isFalse);
    });

    test('both round-trip', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository(await SharedPreferences.getInstance());
      await repo.setInstalledFromPlay(true);
      await repo.setAttestationIneligible(true);
      expect(repo.installedFromPlay, isTrue);
      expect(repo.attestationIneligible, isTrue);
    });

    test('neither is carried by a backup', () async {
      // Both describe THIS install's delivery channel and device, so restoring
      // a backup onto another phone must not import them.
      SharedPreferences.setMockInitialValues({});
      final repo = SettingsRepository(await SharedPreferences.getInstance());
      await repo.setInstalledFromPlay(true);
      await repo.setAttestationIneligible(true);
      expect(repo.exportAll().containsKey('installed_from_play'), isFalse);
      expect(repo.exportAll().containsKey('attestation_ineligible'), isFalse);
    });
  });

  group('attestation ineligibility expiry', () {
    final t0 = DateTime(2026, 10, 1, 12);

    Future<SettingsRepository> repo(Map<String, Object> init) async {
      SharedPreferences.setMockInitialValues(init);
      return SettingsRepository(await SharedPreferences.getInstance());
    }

    Map<String, Object> flagged({String? build}) => {
      'attestation_ineligible': true,
      'attestation_ineligible_since': t0.millisecondsSinceEpoch,
      'last_seen_build': ?build,
    };

    test('flagging records when it happened', () async {
      final r = await repo({});
      await r.setAttestationIneligible(true, now: t0);
      expect(r.attestationIneligibleSince, t0);
      await r.setAttestationIneligible(false);
      expect(r.attestationIneligibleSince, isNull);
    });

    test('the first launch records the build and keeps the flag', () async {
      final r = await repo(flagged());
      final cleared = await r.expireAttestationIneligible(
        build: '30',
        now: t0.add(const Duration(days: 1)),
      );
      expect(cleared, isFalse);
      expect(r.attestationIneligible, isTrue);
    });

    test('the same build within a week keeps the flag', () async {
      final r = await repo(flagged(build: '30'));
      final cleared = await r.expireAttestationIneligible(
        build: '30',
        now: t0.add(const Duration(days: 6)),
      );
      expect(cleared, isFalse);
      expect(r.attestationIneligible, isTrue);
    });

    test('an app update clears it', () async {
      final r = await repo(flagged(build: '30'));
      final cleared = await r.expireAttestationIneligible(
        build: '31',
        now: t0.add(const Duration(days: 1)),
      );
      expect(cleared, isTrue);
      expect(r.attestationIneligible, isFalse);
    });

    test('a week clears it', () async {
      final r = await repo(flagged(build: '30'));
      final cleared = await r.expireAttestationIneligible(
        build: '30',
        now: t0.add(const Duration(days: 7)),
      );
      expect(cleared, isTrue);
    });

    test('a flag with no timestamp is treated as expired', () async {
      final r = await repo({
        'attestation_ineligible': true,
        'last_seen_build': '30',
      });
      expect(await r.expireAttestationIneligible(build: '30', now: t0), isTrue);
    });
  });
}
