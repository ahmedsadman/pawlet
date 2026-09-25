import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/auth_providers.dart';
import 'pin_pad.dart';

enum _Step { current, enter, confirm }

/// Change the PIN: verify the current one, enter a new one, then confirm it.
/// Pushed as a route from Settings.
class ChangePinScreen extends ConsumerStatefulWidget {
  const ChangePinScreen({super.key});

  @override
  ConsumerState<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends ConsumerState<ChangePinScreen> {
  _Step _step = _Step.current;
  String _pin = '';
  String _current = '';
  String _newPin = '';
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
    final controller = ref.read(authControllerProvider.notifier);
    switch (_step) {
      case _Step.current:
        if (await controller.verifyPin(_pin)) {
          setState(() {
            _current = _pin;
            _pin = '';
            _step = _Step.enter;
          });
        } else {
          setState(() {
            _error = 'Incorrect PIN. Try again.';
            _pin = '';
          });
        }
      case _Step.enter:
        setState(() {
          _newPin = _pin;
          _pin = '';
          _step = _Step.confirm;
        });
      case _Step.confirm:
        if (_pin != _newPin) {
          setState(() {
            _error = "PINs don't match. Enter the new PIN again.";
            _pin = '';
            _newPin = '';
            _step = _Step.enter;
          });
          return;
        }
        final ok = await controller.changePin(_current, _newPin);
        if (!mounted) return;
        if (!ok) {
          // The current PIN was verified a step earlier, so this is unexpected;
          // surface it rather than showing a false success.
          setState(() {
            _error = 'Could not update PIN. Try again.';
            _pin = '';
            _newPin = '';
            _current = '';
            _step = _Step.current;
          });
          return;
        }
        Navigator.of(context).pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PIN updated')));
    }
  }

  ({String title, String subtitle}) get _copy => switch (_step) {
    _Step.current => (title: 'Current PIN', subtitle: 'Enter your current PIN'),
    _Step.enter => (title: 'New PIN', subtitle: 'Choose a new 4-digit PIN'),
    _Step.confirm => (title: 'Confirm PIN', subtitle: 'Re-enter your new PIN'),
  };

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return Scaffold(
      appBar: AppBar(title: const Text('Change PIN')),
      body: PinScreenLayout(
        title: copy.title,
        subtitle: copy.subtitle,
        error: _error,
        dots: PinDots(length: 4, filled: _pin.length, error: _error != null),
        pad: PinPad(onDigit: _onDigit, onBackspace: _onBackspace),
      ),
    );
  }
}
