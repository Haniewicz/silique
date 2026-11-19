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
///
/// The pill is exactly as wide as its measured label plus symmetric padding
/// (not a fixed 120 px), and its position is clamped to the window so both
/// rounded caps of the edge actions' pills stay fully visible instead of being
/// cut off by the window edge.
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  /// Geometry of the pill, shared by the text measurement and the painted
  /// container so the measured width always yields a symmetric pill.
  static const _pillHeight = 22.0;
  static const _pillHorizontalPadding = 8.0;
  static const _pillMinWidth = 40.0;
  static const _pillMaxWidth = 260.0;

  /// Keeps a clamped pill's rounded cap off the window edge.
  static const _windowMargin = 4.0;

  /// Vertical gap between the pill and the action's top edge.
  static const _anchorGap = 2.0;

  /// The label style is pinned: the pill must look the same as a plain hover
  /// surface, so the label must never inherit a decoration (the owner reported
  /// an underline that no source style sets).
  static const _labelStyle = TextStyle(
    fontSize: 11,
    color: textStrong,
    decoration: TextDecoration.none,
  );

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
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// The overlay builder only re-runs on its own dependencies; a resize, a text
  /// scale or a display change moves the anchor without rebuilding it, so the
  /// visible pill is repositioned explicitly.
  @override
  void didChangeMetrics() {
    if (_inserted) _entry?.markNeedsBuild();
  }

  @override
  void dispose() {
    // The observer must go before the entry: a metrics callback after `remove`
    // would try to rebuild a disposed overlay entry.
    WidgetsBinding.instance.removeObserver(this);
    if (_inserted) _entry?.remove();
    _controller.dispose();
    super.dispose();
  }

  /// Width of the pill: the measured label plus symmetric padding, clamped so
  /// both a one-letter and an extreme label still produce a sane pill.
  double _pillWidth(BuildContext context) {
    final painter = TextPainter(
      text: TextSpan(text: widget.label, style: _labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = (painter.width + _pillHorizontalPadding * 2).ceilToDouble();
    painter.dispose();
    return width.clamp(_pillMinWidth, _pillMaxWidth).toDouble();
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
        final windowWidth = MediaQuery.sizeOf(context).width;
        final width = _pillWidth(context);
        // Centered on the action, then clamped so the whole pill (both rounded
        // caps) stays inside the window: the edge actions sit within a pill's
        // half-width of an edge, which used to cut the capsule off.
        final maxLeft = math.max(
          _windowMargin,
          windowWidth - width - _windowMargin,
        );
        final left = (pos.dx + box.size.width / 2 - width / 2)
            .clamp(_windowMargin, maxLeft)
            .toDouble();
        return Positioned(
          left: left,
          width: width,
          top: math.max(0, pos.dy - _pillHeight - _anchorGap),
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
                  key: const Key('footer-floating-label-pill'),
                  alignment: Alignment.center,
                  height: _pillHeight,
                  padding: const EdgeInsets.symmetric(
                    horizontal: _pillHorizontalPadding,
                  ),
                  decoration: BoxDecoration(
                    color: menuHover,
                    borderRadius: BorderRadius.circular(_pillHeight / 2),
                  ),
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _labelStyle,
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
