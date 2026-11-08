import 'package:flutter/material.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

/// One document viewport: metadata and editable content share the same offset.
/// The body must size to its content, without an independently scrolling field.
///
/// A single scroll view owns the note offset. A nested scroll view that shares
/// its controller with an editable field resets that offset whenever the field
/// rebuilds, which made typing jump back to the head of the note.
class MobileNoteViewport extends StatefulWidget {
  const MobileNoteViewport({
    super.key,
    required this.heading,
    required this.bodyBuilder,
    this.selectionController,
    this.onBlankTap,
  });

  final Widget heading;
  final Widget Function(ScrollController scroll) bodyBuilder;

  /// Field whose long-press selection drives edge scrolling. Null when the
  /// body already owns its own edge scrolling (the live Markdown editor).
  final TextEditingController? selectionController;
  final VoidCallback? onBlankTap;

  @override
  State<MobileNoteViewport> createState() => _MobileNoteViewportState();
}

class _MobileNoteViewportState extends State<MobileNoteViewport> {
  final _scroll = ScrollController();
  final _body = GlobalKey();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.bodyBuilder(_scroll);
    final controller = widget.selectionController;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: widget.onBlankTap == null
          ? null
          : (details) {
              final box =
                  _body.currentContext?.findRenderObject() as RenderBox?;
              if (box != null &&
                  details.globalPosition.dy >=
                      box.localToGlobal(Offset(0, box.size.height)).dy) {
                widget.onBlankTap!();
              }
            },
      child: SingleChildScrollView(
        key: const Key('mobile-note-scroll'),
        controller: _scroll,
        physics: const ClampingScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            widget.heading,
            KeyedSubtree(
              key: _body,
              child: controller == null
                  ? body
                  :
                    // Stop native reveal before it reaches the document viewport,
                    // just like the live editor's field-local selection boundary.
                    TextSelectionEdgeAutoScroll(
                      controller: controller,
                      scrollController: _scroll,
                      child: body,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
