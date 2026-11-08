import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'live_markdown_controller.dart';

bool get usesDesktopTextContextMenu => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};

/// A full desktop edit menu, including disabled commands. This function only
/// reads Flutter's clipboard status: it never reads clipboard payloads.
List<ContextMenuButtonItem> desktopTextContextMenuItems(
  EditableTextState editable, {
  LiveMarkdownController? document,
  bool Function()? isCurrent,
  VoidCallback? paste,
  String? undoLabel,
  String? redoLabel,
  String? deleteLabel,
}) {
  final polish = Localizations.localeOf(editable.context).languageCode == 'pl';
  // Flutter 3.47 exposes the internally-owned native history only through this
  // documented State. Use the real stack, never a parallel plaintext history.
  // Resolve on demand so a retained menu callback does not retain a disposed
  // native undo stack (in particular, a hidden title's plaintext snapshots).
  // ignore: invalid_use_of_visible_for_testing_member
  UndoHistoryState<TextEditingValue>? nativeHistory() {
    // ignore: invalid_use_of_visible_for_testing_member
    UndoHistoryState<TextEditingValue>? found;
    void visit(Element element) {
      if (element is StatefulElement &&
          // ignore: invalid_use_of_visible_for_testing_member
          element.state is UndoHistoryState<TextEditingValue>) {
        // ignore: invalid_use_of_visible_for_testing_member
        found = element.state as UndoHistoryState<TextEditingValue>;
        return;
      }
      element.visitChildren(visit);
    }

    // Toolbar builders run while the Overlay builds, not while this mounted
    // EditableText subtree is changing. Traverse the stable Element subtree;
    // BuildContext.visitChildElements rejects any build, including that sibling.
    if (editable.mounted && document == null) {
      (editable.context as Element).visitChildren(visit);
    }
    return found;
  }

  final controller = editable.widget.controller;
  bool valid() =>
      editable.mounted &&
      identical(editable.widget.controller, controller) &&
      (isCurrent?.call() ?? true) &&
      editable.textEditingValue.selection.isValid;
  bool writable() => valid() && !editable.widget.readOnly;
  bool selected() =>
      valid() && !editable.textEditingValue.selection.isCollapsed;
  VoidCallback? command(
    bool enabled,
    VoidCallback action, {
    bool writes = false,
  }) => enabled
      ? () {
          if (!(writes ? writable() : valid())) return;
          action();
          editable.hideToolbar();
        }
      : null;
  final writableNow = writable();
  final selection = editable.textEditingValue.selection;
  final text = editable.textEditingValue.text;
  return [
    ContextMenuButtonItem(
      label: undoLabel ?? (polish ? 'Cofnij' : 'Undo'),
      onPressed: command(
        writableNow && (document?.canUndo ?? nativeHistory()?.canUndo ?? false),
        () {
          if (document != null) {
            document.undo();
          } else {
            nativeHistory()?.undo();
          }
        },
        writes: true,
      ),
    ),
    ContextMenuButtonItem(
      label: redoLabel ?? (polish ? 'Ponów' : 'Redo'),
      onPressed: command(
        writableNow && (document?.canRedo ?? nativeHistory()?.canRedo ?? false),
        () {
          if (document != null) {
            document.redo();
          } else {
            nativeHistory()?.redo();
          }
        },
        writes: true,
      ),
    ),
    ContextMenuButtonItem(
      type: ContextMenuButtonType.cut,
      onPressed: command(writableNow && selected() && editable.cutEnabled, () {
        if (selected()) editable.cutSelection(SelectionChangedCause.toolbar);
      }, writes: true),
    ),
    ContextMenuButtonItem(
      type: ContextMenuButtonType.copy,
      onPressed: command(selected() && editable.copyEnabled, () {
        if (selected()) editable.copySelection(SelectionChangedCause.toolbar);
      }),
    ),
    ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      // A configured media importer must remain invocable for image-only
      // clipboards. Admission and late-read revocation remain in that importer.
      onPressed: command(
        writableNow && (paste != null || editable.pasteEnabled),
        paste ??
            () {
              editable.pasteText(SelectionChangedCause.toolbar);
            },
        writes: true,
      ),
    ),
    ContextMenuButtonItem(
      type: ContextMenuButtonType.delete,
      label: deleteLabel ?? (polish ? 'Usuń' : 'Delete'),
      onPressed: command(writableNow && selected(), () {
        if (!selected()) return;
        final value = editable.textEditingValue;
        editable.userUpdateTextEditingValue(
          value
              .replaced(value.selection, '')
              .copyWith(composing: TextRange.empty),
          SelectionChangedCause.toolbar,
        );
      }, writes: true),
    ),
    ContextMenuButtonItem(
      type: ContextMenuButtonType.selectAll,
      onPressed: command(
        valid() &&
            editable.widget.enableInteractiveSelection &&
            !(editable.widget.readOnly && editable.widget.obscureText) &&
            text.isNotEmpty &&
            !(selection.start == 0 && selection.end == text.length),
        () => editable.selectAll(SelectionChangedCause.toolbar),
      ),
    ),
  ];
}
