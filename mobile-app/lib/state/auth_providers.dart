import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../data/auth_repository.dart';
import '../services/biometric_service.dart';
import '../services/screen_lock_channel.dart';

/// The app-lock lifecycle.
///
/// * [unknown]   — still reading secure storage (show a neutral splash).
/// * [needsSetup]— first run, no PIN yet (show PIN setup).
/// * [locked]    — PIN set, awaiting unlock (show the lock screen).
/// * [unlocked]  — authenticated; the app is usable.
enum AuthStatus { unknown, needsSetup, locked, unlocked }

class AuthState {
  const AuthState({
    required this.status,
    this.biometricAvailable = false,
    this.biometricEnabled = false,
  });

  final AuthStatus status;

  /// Device supports biometrics and the user has enrolled at least one.
  final bool biometricAvailable;

  /// User opted into biometric unlock (only ever true when available).
  final bool biometricEnabled;

  bool get canUseBiometric => biometricAvailable && biometricEnabled;

  AuthState copyWith({
    AuthStatus? status,
    bool? biometricAvailable,
    bool? biometricEnabled,
  }) => AuthState(
    status: status ?? this.status,
    biometricAvailable: biometricAvailable ?? this.biometricAvailable,
    biometricEnabled: biometricEnabled ?? this.biometricEnabled,
  );

  @override
  bool operator ==(Object other) =>
      other is AuthState &&
      other.status == status &&
      other.biometricAvailable == biometricAvailable &&
      other.biometricEnabled == biometricEnabled;

  @override
  int get hashCode => Object.hash(status, biometricAvailable, biometricEnabled);
}

// The v11 default AndroidOptions already uses Keystore-backed AES-GCM, so no
// extra options are needed.
final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(),
);

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(secureStorageProvider)),
);

final biometricServiceProvider = Provider<BiometricService>(
  (ref) => BiometricService(),
);

final screenLockChannelProvider = Provider<ScreenLockChannel>(
  (ref) => ScreenLockChannel(),
);

/// Drives the [AuthGate]. Holds the lock status and biometric preferences.
class AuthController extends Notifier<AuthState> {
  @override
  AuthState build() {
    // Kick off the async read; the gate shows a splash while status == unknown.
    _init();
    return const AuthState(status: AuthStatus.unknown);
  }

  AuthRepository get _repo => ref.read(authRepositoryProvider);
  BiometricService get _biometric => ref.read(biometricServiceProvider);
  ScreenLockChannel get _screenLock => ref.read(screenLockChannelProvider);

  Future<void> _init() async {
    try {
      // Existing users updating from a pre-lock version have no stored PIN, so
      // hasPin() reads a missing key and returns false -> needsSetup (the PIN
      // setup flow). Brand-new installs hit the same path.
      final hasPin = await _repo.hasPin();
      final available = await _biometric.isAvailable();
      final enabled = available && await _repo.biometricEnabled;
      state = AuthState(
        status: hasPin ? AuthStatus.locked : AuthStatus.needsSetup,
        biometricAvailable: available,
        biometricEnabled: enabled,
      );
    } catch (_) {
      // Secure storage unreadable (e.g. a keystore hiccup) — fall back to setup
      // so the app stays usable instead of hanging on the splash.
      state = const AuthState(status: AuthStatus.needsSetup);
    }
  }

  /// First-run setup: store the PIN, optionally enable biometric unlock, then
  /// unlock. If the biometric check fails we still unlock (just without it).
  Future<void> setupPin(String pin, {bool enableBiometric = false}) async {
    await _repo.setPin(pin);
    if (enableBiometric &&
        state.biometricAvailable &&
        await _biometric.authenticate()) {
      await _repo.setBiometricEnabled(true);
      state = state.copyWith(biometricEnabled: true);
    }
    state = state.copyWith(status: AuthStatus.unlocked);
  }

  /// Verify the PIN on the lock screen. Returns false (leaving status locked) on
  /// mismatch so the UI can show an error.
  Future<bool> submitPin(String pin) async {
    final ok = await _repo.verifyPin(pin);
    if (ok) state = state.copyWith(status: AuthStatus.unlocked);
    return ok;
  }

  /// Read-only PIN check used by the change-PIN flow (does not change status).
  Future<bool> verifyPin(String pin) => _repo.verifyPin(pin);

  /// Attempt biometric unlock. No-op (returns false) when unavailable/disabled.
  Future<bool> authenticateBiometric() async {
    if (!state.canUseBiometric) return false;
    final ok = await _biometric.authenticate();
    if (ok) state = state.copyWith(status: AuthStatus.unlocked);
    return ok;
  }

  /// Change the PIN after confirming the current one. Returns false if the
  /// current PIN is wrong.
  Future<bool> changePin(String currentPin, String newPin) async {
    if (!await _repo.verifyPin(currentPin)) return false;
    await _repo.setPin(newPin);
    return true;
  }

  /// Toggle biometric unlock. Enabling requires a live biometric check first;
  /// returns false if that check fails.
  Future<bool> setBiometricEnabled(bool value) async {
    if (value) {
      if (!state.biometricAvailable) return false;
      if (!await _biometric.authenticate()) return false;
    }
    await _repo.setBiometricEnabled(value);
    state = state.copyWith(biometricEnabled: value);
    return true;
  }

  /// Force the lock screen (used on device re-lock).
  void lock() {
    if (state.status == AuthStatus.unlocked) {
      state = state.copyWith(status: AuthStatus.locked);
    }
  }

  /// Called when the app returns to the foreground. Always drains the native
  /// screen-off flag (so a flag set while locked can't linger and trigger a
  /// false re-lock on a later app-switch), then re-locks if the device screen
  /// went off while we were away.
  Future<void> onResume() async {
    final screenWasOff = await _screenLock.consumeScreenOff();
    if (screenWasOff && state.status == AuthStatus.unlocked) lock();
  }
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);
