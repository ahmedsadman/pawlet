import 'package:flutter_test/flutter_test.dart';
import 'package:meowni/data/settings_repository.dart';
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

  test('defaultLlmModel is the free router', () {
    expect(SettingsRepository.defaultLlmModel, 'openrouter/free');
  });
}
