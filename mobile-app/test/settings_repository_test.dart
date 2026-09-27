import 'package:flutter_test/flutter_test.dart';
import 'package:pawlet/data/settings_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  Future<SettingsRepository> repo([Map<String, Object> seed = const {}]) async {
    SharedPreferences.setMockInitialValues(seed);
    return SettingsRepository(await SharedPreferences.getInstance());
  }

  test('currency defaults to BDT and upper-cases on set', () async {
    final r = await repo();
    expect(r.currency, 'BDT');
    await r.setCurrency('usd');
    expect(r.currency, 'USD');
  });

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
    final r = await repo({'currency': 'USD', 'hide_balance': true});
    final snap = r.exportAll();
    expect(snap['currency'], 'USD');
    expect(snap['hide_balance'], true);
    // history_hint_seen was never written, so it is absent from the snapshot.
    expect(snap.containsKey('history_hint_seen'), isFalse);
  });

  test('importAll restores a snapshot', () async {
    final r = await repo({'currency': 'USD', 'hide_balance': true});
    final snap = r.exportAll();
    await r.setCurrency('BDT');
    await r.setHideBalance(false);
    await r.importAll(snap);
    expect(r.currency, 'USD');
    expect(r.hideBalance, isTrue);
  });

  test('importAll clears keys missing from the snapshot (replace)', () async {
    final r = await repo({'history_hint_seen': true});
    await r.importAll(const {}); // empty snapshot
    expect(r.historyHintSeen, isFalse); // reset to its default
  });
}
