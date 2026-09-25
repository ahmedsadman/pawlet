import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_providers.dart';
import 'pin_pad.dart';

/// Full-screen lock shown when the app is [AuthStatus.locked]. Auto-prompts
/// biometrics on open when enabled; the PIN keypad is always available.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  String _pin = '';
  bool _error = false;
  bool _prompted = false;

  @override
  void initState() {
    super.initState();
    // Auto-show the biometric prompt on open (no extra tap) when enabled. If the
    // auth state hasn't resolved yet, the listener in build() catches it once it
    // does.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybePrompt());
  }

  void _maybePrompt() {
    if (_prompted || !ref.read(authControllerProvider).canUseBiometric) return;
    _prompted = true;
    _tryBiometric();
  }

  Future<void> _tryBiometric() =>
      ref.read(authControllerProvider.notifier).authenticateBiometric();

  void _onDigit(String d) {
    if (_pin.length >= 4) return;
    setState(() {
      _error = false;
      _pin += d;
    });
    if (_pin.length == 4) _submit();
  }

  void _onBackspace() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  Future<void> _submit() async {
    final ok = await ref.read(authControllerProvider.notifier).submitPin(_pin);
    // On success the gate rebuilds to unlocked and unmounts this screen.
    if (!ok && mounted) {
      setState(() {
        _error = true;
        _pin = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Prompt as soon as biometric readiness becomes true (async init may resolve
    // after this screen first mounts).
    ref.listen(authControllerProvider.select((s) => s.canUseBiometric), (
      _,
      next,
    ) {
      if (next) _maybePrompt();
    });
    final canUseBiometric = ref.watch(
      authControllerProvider.select((s) => s.canUseBiometric),
    );
    return Scaffold(
      body: PinScreenLayout(
        title: 'Enter PIN',
        subtitle: 'Unlock Pawlet to continue',
        error: _error ? 'Incorrect PIN. Try again.' : null,
        dots: PinDots(length: 4, filled: _pin.length, error: _error),
        pad: PinPad(
          onDigit: _onDigit,
          onBackspace: _onBackspace,
          leadingIcon: canUseBiometric ? Icons.fingerprint : null,
          onLeading: canUseBiometric ? _tryBiometric : null,
        ),
      ),
    );
  }
}
