import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// A small "pill" floating label that appears above its child (a sidebar
/// footer action) while the pointer hovers it, fading and scaling in over
/// ~140 ms. It is not a native `Tooltip`: it has no entry delay and renders in
/// the same layer as the folder hover, so both surfaces read identically to
/// the owner hovering the mouse.
///
/// The label is overlaid relative to this widget's own box via a
/// `CompositedTransformFollower`-free `Overlay` anchor computed from the
/// child's render box, so it floats above the footer rather than pushing it.
class FloatingFooterLabel extends StatefulWidget {
  const FloatingFooterLabel({
    super.key,
    required this.label,
    required this.child,
    this.duration = const Duration(milliseconds: 140),
  });

  /// Human-readable action name shown in the pill, already localized.
  final String label;

  /// The footer action this label annotates.
  final Widget child;

  /// Fade/scale animation duration.
  final Duration duration;

  @override
  State<FloatingFooterLabel> createState() => _FloatingFooterLabelState();
}

class _FloatingFooterLabelState extends State<FloatingFooterLabel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    reverseDuration: const Duration(milliseconds: 100),
  );
  late final Animation<double> _fade = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<double> _scale = Tween<double>(
    begin: .9,
    end: 1,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

  final GlobalKey _anchorKey = GlobalKey();
  OverlayEntry? _entry;
  bool _inserted = false;

  @override
  void dispose() {
    if (_inserted) _entry?.remove();
    _controller.dispose();
    super.dispose();
  }

  void _show() {
    // One overlay entry lives for the widget's whole lifetime and is only faded
    // in and out. Inserting/removing per hover raced with the reverse animation
    // and could leave two pills visible at once.
    _entry ??= _buildEntry();
    if (!_inserted && mounted) {
      Overlay.of(context).insert(_entry!);
      _inserted = true;
    }
    _controller.forward();
  }

  void _hide() => _controller.reverse();

  OverlayEntry _buildEntry() {
    final box = _anchorKey.currentContext!.findRenderObject() as RenderBox;
    // Position updated on the next frame so it tolerates relayout.
    final entry = OverlayEntry(
      builder: (context) {
        final pos = box.localToGlobal(Offset.zero);
        final size = box.size;
        return Positioned(
          left: pos.dx - 60 + size.width / 2,
          width: 120,
          top: math.max(0, pos.dy - 24),
          child: IgnorePointer(
            // The pill is a visual mirror of the action's own Semantics label;
            // exposing it separately would announce the name twice.
            child: ExcludeSemantics(
              child: AnimatedBuilder(
                animation: _controller,
                // Nothing stays in the tree while hidden, so the label cannot
                // be found, focused or announced once the pointer left.
                builder: (context, child) => _controller.value == 0
                    ? const SizedBox.shrink()
                    : Opacity(
                        opacity: _fade.value,
                        child: Transform.scale(
                          scale: _scale.value,
                          alignment: Alignment.bottomCenter,
                          child: child,
                        ),
                      ),
                child: Container(
                  alignment: Alignment.center,
                  height: 22,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: menuHover,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: textStrong),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    return entry;
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      key: _anchorKey,
      onEnter: (_) => _show(),
      onExit: (_) => _hide(),
      child: widget.child,
    );
  }
}
