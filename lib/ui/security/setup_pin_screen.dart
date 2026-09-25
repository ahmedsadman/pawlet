import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_providers.dart';
import 'pin_pad.dart';

enum _Step { enter, confirm, biometric }

/// First-run flow: choose a 4-digit PIN, confirm it, then (if the device
/// supports biometrics) optionally enable biometric unlock. Shown as the
/// [AuthStatus.needsSetup] overlay.
class SetupPinScreen extends ConsumerStatefulWidget {
  const SetupPinScreen({super.key});

  @override
  ConsumerState<SetupPinScreen> createState() => _SetupPinScreenState();
}

class _SetupPinScreenState extends ConsumerState<SetupPinScreen> {
  _Step _step = _Step.enter;
  String _pin = '';
  String _first = '';
  String? _error;

  void _onDigit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _error = null;
      _pin += d;
    });
    if (_pin.length == 4) _advance();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _advance() async {
    if (_step == _Step.enter) {
      setState(() {
        _first = _pin;
        _pin = '';
        _step = _Step.confirm;
      });
      return;
    }
    // Confirm step.
    if (_pin != _first) {
      setState(() {
        _error = "PINs don't match. Start over.";
        _pin = '';
        _first = '';
        _step = _Step.enter;
      });
      return;
    }
    if (ref.read(authControllerProvider).biometricAvailable) {
      setState(() => _step = _Step.biometric);
    } else {
      await ref.read(authControllerProvider.notifier).setupPin(_first);
    }
  }

  Future<void> _finish({required bool enableBiometric}) => ref
      .read(authControllerProvider.notifier)
      .setupPin(_first, enableBiometric: enableBiometric);

  @override
  Widget build(BuildContext context) {
    if (_step == _Step.biometric) return _biometricOffer(context);

    final isConfirm = _step == _Step.confirm;
    return Scaffold(
      body: PinScreenLayout(
        icon: Icons.lock_outline,
        title: isConfirm ? 'Confirm PIN' : 'Create a PIN',
        subtitle: isConfirm
            ? 'Re-enter your 4-digit PIN'
            : 'Set a 4-digit PIN to secure the app',
        error: _error,
        dots: PinDots(length: 4, filled: _pin.length),
        pad: PinPad(onDigit: _onDigit, onBackspace: _onBackspace),
      ),
    );
  }

  Widget _biometricOffer(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Icon(
                Icons.fingerprint,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                'Enable biometric unlock?',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Use your fingerprint or face to unlock Pawlet. '
                'You can change this later in Settings.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const Spacer(flex: 3),
              FilledButton(
                onPressed: () => _finish(enableBiometric: true),
                child: const Text('Enable biometrics'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _finish(enableBiometric: false),
                child: const Text('Not now'),
              ),
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
