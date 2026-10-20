import 'package:flutter/material.dart';

/// Grows to reveal [child] while [expanded] and shrinks away when not — the
/// one expand/collapse animation shared across the app (History message rows,
/// Queue, Finance cards, pairing messages).
///
/// The child is built only while expanded, so collapsed content is absent from
/// the tree rather than hidden: on collapse it is swapped at once for empty
/// space of its last height, and only that space animates away. Both states
/// span the full available width, so only the height animates. Needs a bounded
/// width from its parent.
///
/// Driven by its own controller rather than `AnimatedSize`, which snaps
/// straight to the final size when its child resizes mid-animation — exactly
/// what content that loads after it is built does (a skeleton, then the real
/// content).
class ExpandReveal extends StatefulWidget {
  const ExpandReveal({required this.expanded, required this.child, super.key});

  /// How long a reveal or collapse takes.
  static const duration = Duration(milliseconds: 180);

  final bool expanded;
  final Widget child;

  @override
  State<ExpandReveal> createState() => _ExpandRevealState();
}

class _ExpandRevealState extends State<ExpandReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: ExpandReveal.duration,
    value: widget.expanded ? 1 : 0,
  );

  final _contentKey = GlobalKey();

  /// The content's height when it was collapsed, held as empty space while
  /// the collapse plays.
  double _collapsingHeight = 0;

  @override
  void didUpdateWidget(ExpandReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _controller.forward();
    } else {
      // Read from the render box: `context.size` is off-limits during build.
      final box = _contentKey.currentContext?.findRenderObject() as RenderBox?;
      _collapsingHeight = box != null && box.hasSize ? box.size.height : 0;
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizeTransition(
      sizeFactor: _controller,
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: double.infinity,
        child: widget.expanded
            ? KeyedSubtree(key: _contentKey, child: widget.child)
            : SizedBox(height: _collapsingHeight),
      ),
    );
  }
}
