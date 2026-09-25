import 'package:local_auth/local_auth.dart';

/// Thin wrapper over `local_auth` for fingerprint/face unlock. All calls are
/// defensive — any plugin error resolves to "unavailable" / "not authenticated"
/// so the caller can always fall back to the PIN.
class BiometricService {
  BiometricService([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// True only when the device supports biometrics and the user has enrolled at
  /// least one (so we never offer a toggle that can't work).
  Future<bool> isAvailable() async {
    try {
      if (!await _auth.isDeviceSupported()) return false;
      if (!await _auth.canCheckBiometrics) return false;
      return (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Prompts for biometric authentication. Returns false on cancel or error.
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Pawlet',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}
