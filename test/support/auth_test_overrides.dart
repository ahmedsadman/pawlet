import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mocktail/mocktail.dart';
import 'package:pawlet/data/auth_repository.dart';
import 'package:pawlet/services/biometric_service.dart';
import 'package:pawlet/services/screen_lock_channel.dart';
import 'package:pawlet/state/auth_providers.dart';

class MockAuthRepository extends Mock implements AuthRepository {}

class MockBiometricService extends Mock implements BiometricService {}

class MockScreenLockChannel extends Mock implements ScreenLockChannel {}

/// Overrides the auth service providers with mocks so widget tests never reach
/// the secure-storage / biometric plugins. The returned record also exposes the
/// mocks for per-test stubbing.
({
  MockAuthRepository repo,
  MockBiometricService biometric,
  MockScreenLockChannel screenLock,
  List<Override> overrides,
})
authTestOverrides({
  bool hasPin = true,
  bool biometricAvailable = false,
  bool biometricEnabled = false,
}) {
  final repo = MockAuthRepository();
  when(repo.hasPin).thenAnswer((_) async => hasPin);
  when(() => repo.biometricEnabled).thenAnswer((_) async => biometricEnabled);
  when(() => repo.setBiometricEnabled(any())).thenAnswer((_) async {});
  when(() => repo.setPin(any())).thenAnswer((_) async {});
  when(() => repo.verifyPin(any())).thenAnswer((_) async => true);

  final biometric = MockBiometricService();
  when(biometric.isAvailable).thenAnswer((_) async => biometricAvailable);
  when(biometric.authenticate).thenAnswer((_) async => true);

  final screenLock = MockScreenLockChannel();
  when(screenLock.consumeScreenOff).thenAnswer((_) async => false);

  return (
    repo: repo,
    biometric: biometric,
    screenLock: screenLock,
    overrides: [
      authRepositoryProvider.overrideWithValue(repo),
      biometricServiceProvider.overrideWithValue(biometric),
      screenLockChannelProvider.overrideWithValue(screenLock),
    ],
  );
}
