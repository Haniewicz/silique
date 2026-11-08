import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Keep all nested scroll positions fixed while the document surface is pulled.
/// The closure is read by existing drag activities, not just newly built widgets.
class _PullLockPhysics extends ScrollPhysics {
  const _PullLockPhysics({required this.locked, super.parent});
  final bool Function() locked;

  @override
  _PullLockPhysics applyTo(ScrollPhysics? ancestor) =>
      _PullLockPhysics(locked: locked, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) =>
      locked() ? 0 : super.applyPhysicsToUserOffset(position, offset);

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) => locked() ? null : super.createBallisticSimulation(position, velocity);
}

/// Observes touch pulls without competing with the editor's scroll/selection
/// recognizers. Eligibility is latched at pointer down, not when scrolling
/// eventually reaches the top. Nested vertical editors must also be at top.
class TopPullDismiss extends StatefulWidget {
  const TopPullDismiss({
    super.key,
    required this.onDismiss,
    required this.child,
  });

  final FutureOr<void> Function() onDismiss;
  final Widget child;

  @override
  State<TopPullDismiss> createState() => _TopPullDismissState();
}

class _TopPullDismissState extends State<TopPullDismiss>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..addListener(() => setState(() {}));
  Animation<double>? _settling;
  double _offset = 0;
  bool _exiting = false;

  double get _visualOffset => _settling?.value ?? _offset;

  void _settle({bool dismiss = false}) {
    final from = _visualOffset;
    _animation.stop();
    _offset = 0;
    _exiting = dismiss;
    _settling = Tween<double>(
      begin: from,
      end: dismiss ? MediaQuery.sizeOf(context).height : 0,
    ).animate(CurvedAnimation(parent: _animation, curve: Curves.easeOutCubic));
    _animation.forward(from: 0).whenCompleteOrCancel(() async {
      if (!mounted || !_animation.isCompleted) return;
      if (_exiting) {
        try {
          await widget.onDismiss();
        } finally {
          // A failed save leaves this editor mounted: bring it back rather
          // than leaving the note offscreen. Successful navigation disposes it.
          if (mounted) _settle();
        }
      } else if (mounted) {
        setState(() {
          _settling = null;
          _exiting = false;
        });
      }
    });
  }

  int? _pointer;
  final _contacts = <int>{};
  Offset? _start;
  Offset _delta = Offset.zero;
  Timer? _holdTimer;

  @override
  void dispose() {
    _holdTimer?.cancel();
    _animation.dispose();
    super.dispose();
  }

  bool get _atTop {
    var atTop = true;
    void visit(Element element) {
      if (element is StatefulElement && element.state is ScrollableState) {
        final position = (element.state as ScrollableState).position;
        if (axisDirectionToAxis(position.axisDirection) == Axis.vertical &&
            (!position.hasContentDimensions ||
                position.pixels > position.minScrollExtent + .5)) {
          atTop = false;
        }
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return atTop;
  }

  bool get _hasSelection {
    var selected = false;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is EditableText) {
        final selection = widget.controller.selection;
        if (selection.isValid && !selection.isCollapsed) selected = true;
      }
      element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return selected;
  }

  void _reset() {
    _holdTimer?.cancel();
    _pointer = null;
    _start = null;
    _delta = Offset.zero;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) {
      if (_exiting) return;
      _contacts.add(event.pointer);
      if (_contacts.length > 1) {
        // Multi-touch must not turn a pinch/selection into navigation.
        _start = null;
        _settle();
        return;
      }
      _pointer = event.pointer;
      _start = event.kind == PointerDeviceKind.touch && _atTop && !_hasSelection
          ? event.position
          : null;
      _delta = Offset.zero;
      // A held touch belongs to text selection, never pull navigation.
      _holdTimer = Timer(kLongPressTimeout, () {
        if (_offset > 0) return; // A claimed pull can be held and reversed.
        _start = null;
      });
    },
    onPointerMove: (event) {
      if (event.pointer != _pointer || _start == null) return;
      _delta = event.position - _start!;
      // Never reinterpret an upward or horizontal scroll as a dismiss.
      if (_delta.dy < -12 || _delta.dx.abs() > 48 || _hasSelection) {
        _start = null;
        _settle();
        return;
      }
      _animation.stop();
      setState(() {
        _settling = null;
        _offset = _delta.dy > kTouchSlop ? _delta.dy : 0;
      });
    },
    onPointerUp: (event) {
      _contacts.remove(event.pointer);
      if (event.pointer != _pointer) return;
      final dismiss =
          _start != null &&
          _delta.dy >= 80 &&
          _delta.dy > _delta.dx.abs() * 2 &&
          !_hasSelection &&
          _atTop;
      _reset();
      _settle(dismiss: dismiss);
    },
    onPointerCancel: (event) {
      _contacts.remove(event.pointer);
      _reset();
      _settle();
    },
    child: ScrollConfiguration(
      behavior: ScrollConfiguration.of(context).copyWith(
        physics: _PullLockPhysics(
          locked: () => _visualOffset > 0 || _exiting,
          parent: ScrollConfiguration.of(context).getScrollPhysics(context),
        ),
      ),
      child: Transform.translate(
        offset: Offset(0, _visualOffset),
        child: widget.child,
      ),
    ),
  );
}
