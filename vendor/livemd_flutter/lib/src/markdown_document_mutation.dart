import 'package:flutter/widgets.dart';

/// Package-internal exact replacement used to track a pending paste target.
class MarkdownSourceEdit {
  const MarkdownSourceEdit(this.start, this.end, this.insertedLength);

  final int start;
  final int end;
  final int insertedLength;
  int get delta => insertedLength - (end - start);

  bool matches(String before, String after) =>
      start >= 0 &&
      end >= start &&
      end <= before.length &&
      start + insertedLength <= after.length &&
      before.length + delta == after.length &&
      before.substring(0, start) == after.substring(0, start) &&
      before.substring(end) == after.substring(start + insertedLength);

  /// Infer only edits whose location follows the old selection and new caret.
  /// A common-prefix diff cannot locate an edit unambiguously in repeated text.
  static MarkdownSourceEdit? fromEditingValues(
    TextEditingValue before,
    TextEditingValue after,
  ) {
    if (!before.selection.isValid || !after.selection.isCollapsed) return null;
    final selection = before.selection;
    final difference = after.text.length - before.text.length;
    final inserted = difference + selection.end - selection.start;
    final replacement = MarkdownSourceEdit(
      selection.start,
      selection.end,
      inserted,
    );
    if (inserted >= 0 &&
        after.selection.extentOffset == selection.start + inserted &&
        replacement.matches(before.text, after.text)) {
      return replacement;
    }
    if (selection.isCollapsed && difference < 0) {
      final caret = selection.extentOffset;
      final nextCaret = after.selection.extentOffset;
      final deletion = nextCaret == caret + difference
          ? MarkdownSourceEdit(nextCaret, caret, 0)
          : nextCaret == caret
          ? MarkdownSourceEdit(caret, caret - difference, 0)
          : null;
      if (deletion?.matches(before.text, after.text) ?? false) return deletion;
    }
    return null;
  }
}

class MarkdownDocumentMutation {
  const MarkdownDocumentMutation(
    this.before,
    this.after, {
    this.edit,
    this.invalidate = false,
  });
  final TextEditingValue before;
  final TextEditingValue after;
  final MarkdownSourceEdit? edit;
  final bool invalidate;
}

/// Synchronous notifications, including no-op undo and controller disposal.
class MarkdownMutationNotifications {
  final Set<void Function(MarkdownDocumentMutation)> _listeners = {};
  void addListener(void Function(MarkdownDocumentMutation) listener) =>
      _listeners.add(listener);
  void removeListener(void Function(MarkdownDocumentMutation) listener) =>
      _listeners.remove(listener);
  void emit(MarkdownDocumentMutation mutation) {
    for (final listener in List.of(_listeners)) {
      if (_listeners.contains(listener)) listener(mutation);
    }
  }

  void clear() => _listeners.clear();
}

/// Right-affine caret; insertions on the edges of a selection stay outside it.
TextRange? mapMarkdownPasteRange(TextRange range, MarkdownSourceEdit edit) {
  if (edit.start == edit.end) {
    if (edit.start <= range.start) {
      return TextRange(
        start: range.start + edit.delta,
        end: range.end + edit.delta,
      );
    }
    if (edit.start >= range.end) return range;
    return null;
  }
  if (edit.end <= range.start) {
    return TextRange(
      start: range.start + edit.delta,
      end: range.end + edit.delta,
    );
  }
  if (edit.start >= range.end &&
      !(range.isCollapsed && edit.start == range.start)) {
    return range;
  }
  return null;
}

int mapMarkdownOffset(int offset, MarkdownSourceEdit edit) {
  if (offset < edit.start) return offset;
  if (offset >= edit.end) return offset + edit.delta;
  return edit.start + edit.insertedLength;
}
