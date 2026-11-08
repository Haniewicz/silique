import 'package:flutter/material.dart';

typedef MarkdownSelectionToolbarBuilder = Widget Function(
  BuildContext context,
  TextSelectionToolbarAnchors anchors,
  List<ContextMenuButtonItem> items,
);
typedef MarkdownMenuEntryBuilder = PopupMenuEntry<Object> Function(
  BuildContext context,
  Object value,
  String label,
  IconData icon,
  bool enabled,
);

/// Optional application-owned presentation. This package never imports its host.
/// Only appearance is delegated; editing actions and clipboard admission stay here.
class MarkdownMenuPresentation extends InheritedWidget {
  const MarkdownMenuPresentation({
    super.key,
    required super.child,
    required this.selectionToolbarBuilder,
    required this.menuEntryBuilder,
  });
  final MarkdownSelectionToolbarBuilder selectionToolbarBuilder;
  final MarkdownMenuEntryBuilder menuEntryBuilder;
  static MarkdownMenuPresentation? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<MarkdownMenuPresentation>();
  static PopupMenuEntry<Object> entry(
    BuildContext context,
    Object value,
    String label,
    IconData icon, {
    bool enabled = true,
  }) =>
      maybeOf(context)
          ?.menuEntryBuilder(context, value, label, icon, enabled) ??
      PopupMenuItem<Object>(value: value, enabled: enabled, child: Text(label));
  @override
  bool updateShouldNotify(MarkdownMenuPresentation oldWidget) =>
      oldWidget.selectionToolbarBuilder != selectionToolbarBuilder ||
      oldWidget.menuEntryBuilder != menuEntryBuilder;
}
