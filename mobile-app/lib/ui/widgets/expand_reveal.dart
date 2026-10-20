import 'package:flutter/material.dart';

/// Grows to reveal [child] while [expanded] and shrinks away when not — the
/// one expand/collapse animation shared across the app (History message rows,
/// Queue, Finance cards, pairing messages).
///
/// The child is built only while expanded, so collapsed content is absent from
/// the tree rather than hidden. Both states span the full available width, so
/// only the height animates. Needs a bounded width from its parent.
class ExpandReveal extends StatelessWidget {
  const ExpandReveal({required this.expanded, required this.child, super.key});

  /// How long a reveal or collapse takes.
  static const duration = Duration(milliseconds: 180);

  final bool expanded;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: duration,
      alignment: Alignment.topCenter,
      child: SizedBox(width: double.infinity, child: expanded ? child : null),
    );
  }
}
