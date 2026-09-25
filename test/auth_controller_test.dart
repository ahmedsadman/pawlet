import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/state/auth_providers.dart';

import 'support/auth_test_overrides.dart';

// Lets the async _init() (a few awaited mock futures) run to completion.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('starts in needsSetup when there is no PIN', () async {
    final t = authTestOverrides(hasPin: false);
    final container = ProviderContainer(overrides: t.overrides);
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await _settle();
    expect(
      container.read(authControllerProvider).status,
      AuthStatus.needsSetup,
    );
  });

  test('starts locked when a PIN exists', () async {
    final t = authTestOverrides(hasPin: true);
    final container = ProviderContainer(overrides: t.overrides);
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await _settle();
    expect(container.read(authControllerProvider).status, AuthStatus.locked);
  });

  test('submitPin unlocks on a match and stays locked otherwise', () async {
    final t = authTestOverrides(hasPin: true);
    when(() => t.repo.verifyPin('1234')).thenAnswer((_) async => true);
    when(() => t.repo.verifyPin('0000')).thenAnswer((_) async => false);
    final container = ProviderContainer(overrides: t.overrides);
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await _settle();
    final notifier = container.read(authControllerProvider.notifier);

    expect(await notifier.submitPin('0000'), isFalse);
    expect(container.read(authControllerProvider).status, AuthStatus.locked);

    expect(await notifier.submitPin('1234'), isTrue);
    expect(container.read(authControllerProvider).status, AuthStatus.unlocked);
  });

  test('re-locks on resume only when the screen went off', () async {
    final t = authTestOverrides(hasPin: true);
    final container = ProviderContainer(overrides: t.overrides);
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await _settle();
    final notifier = container.read(authControllerProvider.notifier);
    await notifier.submitPin('1234'); // default verifyPin -> true -> unlocked
    expect(container.read(authControllerProvider).status, AuthStatus.unlocked);

    when(t.screenLock.consumeScreenOff).thenAnswer((_) async => false);
    await notifier.onResume();
    expect(container.read(authControllerProvider).status, AuthStatus.unlocked);

    when(t.screenLock.consumeScreenOff).thenAnswer((_) async => true);
    await notifier.onResume();
    expect(container.read(authControllerProvider).status, AuthStatus.locked);
  });

  test('enabling biometrics requires a successful check', () async {
    final t = authTestOverrides(hasPin: true, biometricAvailable: true);
    final container = ProviderContainer(overrides: t.overrides);
    addTearDown(container.dispose);
    container.read(authControllerProvider);
    await _settle();
    final notifier = container.read(authControllerProvider.notifier);

    when(t.biometric.authenticate).thenAnswer((_) async => false);
    expect(await notifier.setBiometricEnabled(true), isFalse);
    expect(container.read(authControllerProvider).biometricEnabled, isFalse);

    when(t.biometric.authenticate).thenAnswer((_) async => true);
    expect(await notifier.setBiometricEnabled(true), isTrue);
    expect(container.read(authControllerProvider).biometricEnabled, isTrue);
    verify(() => t.repo.setBiometricEnabled(true)).called(1);
  });
}
