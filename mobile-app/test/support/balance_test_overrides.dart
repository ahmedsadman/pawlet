import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:pawlet/state/providers.dart';

/// Pins [balanceHiddenProvider] to a fixed value without touching
/// SharedPreferences (widget tests that only render masked/unmasked values).
Override overrideBalanceHidden(bool value) =>
    balanceHiddenProvider.overrideWith(() => _FixedBalanceHidden(value));

class _FixedBalanceHidden extends BalanceHidden {
  _FixedBalanceHidden(this.value);
  final bool value;
  @override
  bool build() => value;
}
