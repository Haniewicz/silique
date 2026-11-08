import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;

class _SelectionRevealBoundary extends SingleChildRenderObjectWidget {
  const _SelectionRevealBoundary({required this.blocked, required super.child});
  final bool Function() blocked;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelectionRevealBoundary(blocked);
  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderSelectionRevealBoundary renderObject,
  ) => renderObject.blocked = blocked;
}

class _RenderSelectionRevealBoundary extends RenderProxyBox {
  _RenderSelectionRevealBoundary(this.blocked);
  bool Function() blocked;
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!blocked()) {
      super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
    }
  }
}

class _SelectionScrollPhysics extends ScrollPhysics {
  const _SelectionScrollPhysics({required this.selectionActive, super.parent});
  final bool Function() selectionActive;

  @override
  _SelectionScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _SelectionScrollPhysics(
        selectionActive: selectionActive,
        parent: buildParent(ancestor),
      );

  // Native caret reveal (including keyboard metrics) must not compete with
  // range selection. Explicit drag/autoscroll and programmatic scrolling remain.
  @override
  bool get allowImplicitScrolling =>
      !selectionActive() && super.allowImplicitScrolling;
}

// Handles live in Overlay, outside the field's Listener hit-test ancestry.
// Forward their raw events without competing with Flutter's drag recognizer.
class _EdgeHandleControls extends MaterialTextSelectionControls
    with TextSelectionHandleControls {
  _EdgeHandleControls(this.owner);
  final _TextSelectionEdgeAutoScrollState owner;

  // Own the full native touch target, not only the 22px painted handle. The
  // framework's external padding otherwise lies outside this raw Listener.
  @override
  Size getHandleSize(double textLineHeight) {
    final visual = super.getHandleSize(textLineHeight);
    return Size(
      visual.width.clamp(kMinInteractiveDimension, double.infinity),
      visual.height.clamp(kMinInteractiveDimension, double.infinity),
    );
  }

  @override
  Offset getHandleAnchor(TextSelectionHandleType type, double textLineHeight) {
    final visual = super.getHandleSize(textLineHeight);
    final target = getHandleSize(textLineHeight);
    return super.getHandleAnchor(type, textLineHeight) +
        Offset(
          (target.width - visual.width) / 2,
          (target.height - visual.height) / 2,
        );
  }

  @override
  Widget buildHandle(
    BuildContext context,
    TextSelectionHandleType type,
    double textLineHeight, [
    VoidCallback? onTap,
  ]) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerDown: (event) => owner._handleDown(event, type),
    onPointerMove: owner._move,
    onPointerUp: owner._up,
    onPointerCancel: owner._up,
    child: SizedBox.fromSize(
      size: getHandleSize(textLineHeight),
      child: Center(
        child: super.buildHandle(context, type, textLineHeight, onTap),
      ),
    ),
  );
}

class _EdgeHandleScope extends InheritedWidget {
  const _EdgeHandleScope({required this.controls, required super.child});
  final TextSelectionControls controls;
  @override
  bool updateShouldNotify(_EdgeHandleScope oldWidget) =>
      controls != oldWidget.controls;
}

/// Adds continuous edge scrolling to a vertically scrolling text field.
///
/// Flutter handles long-press recognition and initial word selection. This only
/// starts after that selection exists, and uses Flutter's edge scroller rather
/// than a pointer polling loop. The same wrapper works with source TextFields.
class TextSelectionEdgeAutoScroll extends StatefulWidget {
  const TextSelectionEdgeAutoScroll({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.child,
  });

  final TextEditingController controller;
  final ScrollController scrollController;
  final Widget child;

  /// Use inside a Builder below this wrapper for Android overlay handle drags.
  /// Other platforms retain their native selection controls.
  static TextSelectionControls? controlsOf(BuildContext context) {
    final platform = Theme.of(context).platform;
    if (platform != TargetPlatform.android &&
        platform != TargetPlatform.fuchsia) {
      return null;
    }
    return context
        .dependOnInheritedWidgetOfExactType<_EdgeHandleScope>()
        ?.controls;
  }

  @override
  State<TextSelectionEdgeAutoScroll> createState() =>
      _TextSelectionEdgeAutoScrollState();
}

class _TextSelectionEdgeAutoScrollState
    extends State<TextSelectionEdgeAutoScroll> {
  Timer? _longPressTimer;
  int? _pointer;
  Offset? _origin;
  Offset? _position;
  double _startScroll = 0;
  bool _longPressReady = false;
  EdgeDraggingAutoScroller? _autoScroller;
  late final _handleControls = _EdgeHandleControls(this);
  bool _handleDragging = false;
  bool _startHandle = false;
  int? _fixedOffset;
  Offset _handleTargetOffset = Offset.zero;

  bool get _selecting =>
      _pointer != null &&
      _longPressReady &&
      widget.controller.selection.isValid &&
      !widget.controller.selection.isCollapsed;

  EditableTextState? _editable() {
    EditableTextState? result;
    void visit(Element element) {
      if (element is StatefulElement && element.state is EditableTextState) {
        final state = element.state as EditableTextState;
        if (state.widget.controller == widget.controller) result = state;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return result;
  }

  void _stop() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _pointer = null;
    _origin = null;
    _position = null;
    _longPressReady = false;
    _handleDragging = false;
    _fixedOffset = null;
    final scroller = _autoScroller;
    _autoScroller = null;
    if (scroller != null) {
      final scrolling = scroller.scrolling;
      scroller.stopAutoScroll();
      // stopAutoScroll stops repetition, not the in-flight animateTo.
      if (scrolling && scroller.scrollable.mounted) {
        final position = scroller.scrollable.position;
        position.jumpTo(position.pixels);
      }
    }
  }

  void _down(PointerDownEvent event) {
    if (_pointer != null) {
      _stop(); // Multitouch must never extend a one-finger text selection.
      return;
    }
    if (event.kind != PointerDeviceKind.touch ||
        !widget.scrollController.hasClients) {
      return;
    }
    _pointer = event.pointer;
    _origin = _position = event.position;
    _startScroll = widget.scrollController.offset;
    _longPressTimer = Timer(kLongPressTimeout, () => _longPressReady = true);
  }

  void _up(PointerEvent event) {
    if (_pointer == event.pointer) _stop();
  }

  void _handleDown(PointerDownEvent event, TextSelectionHandleType type) {
    if (!mounted || widget.controller.selection.isCollapsed) return;
    final editable = _editable();
    if (editable == null) return;
    _down(event);
    if (_pointer != event.pointer) return;
    _longPressTimer?.cancel();
    _longPressReady = true;
    _handleDragging = true;
    final render = editable.renderEditable;
    final selection = widget.controller.selection;
    final endpoints = render.getEndpointsForSelection(selection);
    final start = render.localToGlobal(endpoints.first.point);
    final end = render.localToGlobal(endpoints.last.point);
    // Match TextSelectionOverlay._chooseType: type identifies the native
    // overlay that won hit testing, even when its 48px target overlaps the
    // other endpoint. Flutter chooses types from the paragraph direction,
    // not pointer proximity (nor the direction of an individual bidi run).
    _startHandle =
        type ==
        (render.textDirection == TextDirection.ltr
            ? TextSelectionHandleType.left
            : TextSelectionHandleType.right);
    _fixedOffset = _startHandle ? selection.end : selection.start;
    _handleTargetOffset =
        (_startHandle ? start : end) -
        event.position -
        Offset(0, render.preferredLineHeight / 2);
  }

  void _move(PointerMoveEvent event) {
    if (_pointer != event.pointer) return;
    if (!_longPressReady && (event.position - _origin!).distance > kTouchSlop) {
      _stop(); // An ordinary pan lost the native long-press gesture arena.
      return;
    }
    _position = event.position;
    // Native recognizers process this same event after the raw listener.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _pointer != event.pointer ||
          !_longPressReady ||
          widget.controller.selection.isCollapsed) {
        return;
      }
      final editable = _editable();
      if (editable == null || !widget.scrollController.hasClients) return;
      final scrollable = widget.scrollController.position.context;
      if (scrollable is! ScrollableState) return;
      _autoScroller ??= EdgeDraggingAutoScroller(
        scrollable,
        velocityScalar: 12,
        onScrollViewScrolled: _extendSelection,
      );
      // Inflate the pointer into a 48px edge zone, inside the visible viewport.
      _autoScroller!.startAutoScrollIfNecessary(
        Rect.fromCenter(
          center: _position!,
          width: 1,
          height: editable.renderEditable.size.height.clamp(0.0, 96.0),
        ),
      );
    });
  }

  void _extendSelection() {
    if (!mounted ||
        _pointer == null ||
        _origin == null ||
        _position == null ||
        !widget.scrollController.hasClients) {
      return;
    }
    final editable = _editable();
    if (editable == null ||
        !editable.widget.focusNode.hasFocus ||
        widget.controller.selection.isCollapsed) {
      _stop();
      return;
    }
    if (_handleDragging) {
      final position = editable.renderEditable.getPositionForPoint(
        _position! + _handleTargetOffset,
      );
      final fixed = _fixedOffset!;
      // Match Android's native handles: moving one end never swaps their order.
      if ((_startHandle && position.offset < fixed) ||
          (!_startHandle && position.offset > fixed)) {
        editable.userUpdateTextEditingValue(
          widget.controller.value.copyWith(
            selection: TextSelection(
              baseOffset: _startHandle ? position.offset : fixed,
              extentOffset: _startHandle ? fixed : position.offset,
            ),
          ),
          SelectionChangedCause.drag,
        );
      }
    } else {
      editable.renderEditable.selectWordsInRange(
        from:
            _origin! - Offset(0, widget.scrollController.offset - _startScroll),
        to: _position!,
        cause: SelectionChangedCause.longPress,
      );
    }
    // Refresh the document-relative target as the viewport moves under a
    // stationary finger; otherwise EdgeDraggingAutoScroller stops after one step.
    _autoScroller?.startAutoScrollIfNecessary(
      Rect.fromCenter(
        center: _position!,
        width: 1,
        height: editable.renderEditable.size.height.clamp(0.0, 96.0),
      ),
    );
  }

  @override
  void didUpdateWidget(TextSelectionEdgeAutoScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.scrollController != widget.scrollController) {
      _stop();
    }
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _down,
    onPointerMove: _move,
    onPointerUp: _up,
    onPointerCancel: _up,
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        physics: _SelectionScrollPhysics(
          selectionActive: () => _selecting,
          parent: ScrollConfiguration.of(context).getScrollPhysics(context),
        ),
      ),
      child: _SelectionRevealBoundary(
        blocked: () => _selecting,
        child: _EdgeHandleScope(controls: _handleControls, child: widget.child),
      ),
    ),
  );
}
