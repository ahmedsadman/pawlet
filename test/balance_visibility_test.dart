import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:meowni/data/settings_repository.dart';
import 'package:meowni/state/providers.dart';

void main() {
  ProviderContainer containerFor(SettingsRepository repo) {
    final container = ProviderContainer(
      overrides: [settingsRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('defaults to shown (not hidden)', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository(await SharedPreferences.getInstance());
    expect(containerFor(repo).read(balanceHiddenProvider), isFalse);
  });

  test('reads the persisted hidden state on build', () async {
    SharedPreferences.setMockInitialValues({'hide_balance': true});
    final repo = SettingsRepository(await SharedPreferences.getInstance());
    expect(containerFor(repo).read(balanceHiddenProvider), isTrue);
  });

  test('toggle flips the value and persists it', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = SettingsRepository(await SharedPreferences.getInstance());
    final container = containerFor(repo);

    await container.read(balanceHiddenProvider.notifier).toggle();

    expect(container.read(balanceHiddenProvider), isTrue);
    expect(repo.hideBalance, isTrue);
  });
}
