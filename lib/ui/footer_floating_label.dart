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

  /// Metrics-change notifications arrive before the new frame is laid out, so
  /// the anchor still reports its old global position. The rebuild is therefore
  /// deferred until after the frame: the entry then measures the new layout.
  /// A plain `markNeedsBuild` here ran in the build phase and kept the pill at
  /// its stale position (e.g. 400 px away after a vertical resize).
  void _refreshAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _inserted) _entry?.markNeedsBuild();
    });
  }

  @override
  void didChangeMetrics() => _refreshAfterLayout();

  /// A text scale or directionality change moves the pill too, and arrives in
  /// the build phase as well, so it needs the same post-frame refresh.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _refreshAfterLayout();
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

  /// The label style is built explicitly from the theme. A bare `OverlayEntry`
  /// is not under a `Material`/`DefaultTextStyle`, so it would otherwise inherit
  /// `DefaultTextStyle.fallback()` — monospace, w900, yellow double underline —
  /// instead of the UI font.
  TextStyle _labelStyle(BuildContext context) => TextStyle(
    fontFamily:
        Theme.of(context).textTheme.bodyMedium?.fontFamily ?? kUiFontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    color: textStrong,
    // Pin the pill look; the label must never inherit a decoration.
    decoration: TextDecoration.none,
  );

  /// Width of the pill: the measured label plus symmetric padding, clamped so
  /// both a one-letter and an extreme label still produce a sane pill. It
  /// measures exactly [style], the same object the label is rendered with.
  double _pillWidth(BuildContext context, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: widget.label, style: style),
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
    // A repeat hover must re-measure the anchor: the layout may have moved the
    // action since the entry was built (resize, collapsed sidebar, text scale).
    _entry?.markNeedsBuild();
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
        final labelStyle = _labelStyle(context);
        final width = _pillWidth(context, labelStyle);
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
                  child: DefaultTextStyle(
                    style: labelStyle,
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
