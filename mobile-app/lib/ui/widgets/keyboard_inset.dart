import 'package:flutter/material.dart';

/// Applies the keyboard (IME) inset as bottom padding in isolation. Only this
/// leaf depends on `MediaQuery`, so a keyboard show/hide rebuilds just this
/// widget — not the (potentially expensive) sheet/form subtree passed as
/// [child].
///
/// The bottom pad is a single `max(viewInsets, viewPadding)`: it lifts the
/// content above the keyboard when open, and rests above the system nav bar when
/// closed. Computing it in one place (rather than nesting a bottom `SafeArea`
/// that shrinks while this grows) keeps the pad monotonic through the IME
/// animation, avoiding a per-frame wobble. Wrap with `SafeArea(bottom: false)`.
///
/// Uses a plain [Padding] (not [AnimatedPadding]) so the content tracks the
/// platform's own per-frame IME animation exactly; a self-run tween would trail
/// the keyboard and read as lag. Intended for the content of an
/// `isScrollControlled` bottom sheet whose body is itself scrollable.
class KeyboardInset extends StatelessWidget {
  const KeyboardInset({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final safe = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: insets > safe ? insets : safe),
      child: child,
    );
  }
}
