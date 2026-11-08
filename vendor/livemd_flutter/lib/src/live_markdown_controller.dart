import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/widgets.dart';
import 'package:meta/meta.dart' show internal;

import 'live_markdown_annotation.dart';
import 'markdown_document_mutation.dart';

/// Owns the lossless Markdown source and its global editing state.
///
/// Create once for an editor page and call [dispose] when its owner is removed.
/// Listeners receive text, selection, and composing changes; compare [text]
/// when only document content matters. This controller does not save data.
/// History is in memory and retains at most 200 undo snapshots. Use a new
/// controller when switching to an unrelated document to avoid shared history.
class LiveMarkdownController extends ChangeNotifier {
  /// Creates a document with [text] and a selection clamped to its bounds.
  /// The default caret is at offset zero; offsets count UTF-16 code units.
  LiveMarkdownController({String text = '', TextSelection? selection})
    : _value = _normalizeValue(
        TextEditingValue(
          text: text,
          selection: selection ?? const TextSelection.collapsed(offset: 0),
        ),
      );

  TextEditingValue _value;
  int _revision = 0;
  final List<_DocumentSnapshot> _undoStack = [];
  final List<_DocumentSnapshot> _redoStack = [];
  List<LiveMarkdownAnnotation> _annotations = const [];

  /// Internal source-edit notifications for asynchronous editor operations.
  @internal
  final MarkdownMutationNotifications mutations =
      MarkdownMutationNotifications();

  /// The complete document editing state.
  TextEditingValue get value => _value;

  /// The complete original Markdown, including currently hidden delimiters.
  String get text => _value.text;

  /// The document-global selection, in UTF-16 code units.
  TextSelection get selection => _value.selection;

  /// The document-global IME composing range, or [TextRange.empty].
  TextRange get composing => _value.composing;

  /// Increases whenever [value] actually changes, including selection-only
  /// and composing-only updates.
  int get revision => _revision;

  /// Whether [undo] can restore an earlier editing state.
  bool get canUndo => _undoStack.isNotEmpty;

  /// Whether [redo] can restore an undone editing state.
  bool get canRedo => _redoStack.isNotEmpty;

  /// Presentation-only overlays, for example search matches.
  ///
  /// Annotations never enter the document text or the undo history. The editor
  /// repaints when the list instance changes; pass a new list to update them.
  List<LiveMarkdownAnnotation> get annotations => _annotations;

  /// Replaces the overlay list and repaints the editor when it differs.
  void setAnnotations(List<LiveMarkdownAnnotation> value) {
    if (listEquals(value, _annotations)) return;
    _annotations = List.unmodifiable(value);
    notifyListeners();
  }

  /// Replaces the source using [setText] and records an undo step by default.
  set text(String value) => setText(value);

  /// Replaces the complete editing state.
  ///
  /// Selection-only and composing-only changes notify listeners but are not
  /// added to the undo history. When [mergeWithPrevious] is true, a text edit
  /// is folded into the preceding edit if both use equal, non-null [origin]
  /// values. This gives callers a small transaction model without making the
  /// controller responsible for deciding where an interaction begins or ends.
  /// Out-of-bounds offsets are clamped; invalid composing ranges are cleared.
  /// Setting [addToHistory] to false skips a new undo snapshot, but does not
  /// clear existing undo history. Any text change invalidates redo history.
  void setValue(
    TextEditingValue value, {
    bool addToHistory = true,
    Object? origin,
    bool mergeWithPrevious = false,
  }) => _setValue(
    value,
    addToHistory: addToHistory,
    origin: origin,
    mergeWithPrevious: mergeWithPrevious,
  );

  /// Commits native editing updates with selection-validated source mapping.
  @internal
  void applyEditingValue(
    TextEditingValue value, {
    Object? origin,
    bool mergeWithPrevious = false,
  }) => _setValue(
    value,
    origin: origin,
    mergeWithPrevious: mergeWithPrevious,
    edit: MarkdownSourceEdit.fromEditingValues(_value, value),
  );

  void _setValue(
    TextEditingValue value, {
    bool addToHistory = true,
    Object? origin,
    bool mergeWithPrevious = false,
    MarkdownSourceEdit? edit,
  }) {
    final nextValue = _normalizeValue(value);
    if (nextValue == _value) return;

    final textChanged = nextValue.text != _value.text;
    if (textChanged) {
      if (addToHistory) {
        _recordUndo(origin: origin, mergeWithPrevious: mergeWithPrevious);
      } else {
        _redoStack.clear();
      }
    }

    final previous = _value;
    _value = nextValue;
    _revision++;
    mutations.emit(MarkdownDocumentMutation(previous, nextValue, edit: edit));
    notifyListeners();
  }

  /// Replaces all Markdown, retaining and clamping the current selection
  /// unless [selection] is supplied. A text change clears IME composition.
  /// History options have the same meaning as in [setValue].
  void setText(
    String value, {
    TextSelection? selection,
    bool addToHistory = true,
    Object? origin,
    bool mergeWithPrevious = false,
  }) {
    final textChanged = value != text;
    setValue(
      TextEditingValue(
        text: value,
        selection: selection ?? this.selection,
        composing: textChanged ? TextRange.empty : composing,
      ),
      addToHistory: addToHistory,
      origin: origin,
      mergeWithPrevious: mergeWithPrevious,
    );
  }

  /// Moves the global selection without recording undo history.
  void setSelection(TextSelection value) {
    setValue(_value.copyWith(selection: value), addToHistory: false);
  }

  /// Replaces an exact source range and places the selection in the resulting
  /// document. This is used by structural editing slots between Markdown
  /// blocks where there is no visible source text to own a regular TextField.
  /// [start] is inclusive and [end] exclusive, in UTF-16 code units.
  /// Invalid bounds throw [RangeError]. Without [selection], the caret moves
  /// to the end of the replacement. History options follow [setValue].
  /// Text changes clear composition unless [composing] is supplied; no-op text
  /// replacements preserve the existing composition by default.
  void replaceRange(
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
    TextRange? composing,
    Object? origin,
    bool mergeWithPrevious = false,
  }) {
    if (start < 0 || end < start || end > text.length) {
      throw RangeError.range(start, 0, text.length, 'start');
    }
    final nextText = text.replaceRange(start, end, replacement);
    _setValue(
      TextEditingValue(
        text: nextText,
        selection:
            selection ??
            TextSelection.collapsed(offset: start + replacement.length),
        composing:
            composing ?? (nextText == text ? this.composing : TextRange.empty),
      ),
      origin: origin,
      mergeWithPrevious: mergeWithPrevious,
      edit: MarkdownSourceEdit(start, end, replacement.length),
    );
  }

  /// Applies only the changed slice between two versions of an active block.
  ///
  /// Advanced integration: [blockStart] is document-global; [localSelection]
  /// and [localComposing] are relative to [newSource]. The caller must ensure
  /// [oldSource] still matches the block in the current document. An edit whose
  /// computed replacement range falls outside the document is ignored.
  void applyBlockEdit({
    required int blockStart,
    required String oldSource,
    required String newSource,
    required TextSelection localSelection,
    TextRange? localComposing,
    Object? origin,
    bool mergeWithPrevious = false,
  }) {
    var prefix = 0;
    final shortest = oldSource.length < newSource.length
        ? oldSource.length
        : newSource.length;
    while (prefix < shortest &&
        oldSource.codeUnitAt(prefix) == newSource.codeUnitAt(prefix)) {
      prefix++;
    }

    var suffix = 0;
    while (suffix < shortest - prefix &&
        oldSource.codeUnitAt(oldSource.length - 1 - suffix) ==
            newSource.codeUnitAt(newSource.length - 1 - suffix)) {
      suffix++;
    }

    final replaceStart = blockStart + prefix;
    final replaceEnd = blockStart + oldSource.length - suffix;
    if (replaceStart < 0 || replaceEnd > text.length) return;

    final replacement = newSource.substring(prefix, newSource.length - suffix);
    final nextText = text.replaceRange(replaceStart, replaceEnd, replacement);
    final globalSelection = TextSelection(
      baseOffset: blockStart + localSelection.baseOffset,
      extentOffset: blockStart + localSelection.extentOffset,
      affinity: localSelection.affinity,
      isDirectional: localSelection.isDirectional,
    );
    final globalComposing = localComposing == null || !localComposing.isValid
        ? TextRange.empty
        : TextRange(
            start: blockStart + localComposing.start,
            end: blockStart + localComposing.end,
          );
    setValue(
      TextEditingValue(
        text: nextText,
        selection: globalSelection,
        composing: globalComposing,
      ),
      origin: origin,
      mergeWithPrevious: mergeWithPrevious,
    );
  }

  /// Restores the previous text, selection, and composition; otherwise a no-op.
  void undo() {
    mutations.emit(MarkdownDocumentMutation(_value, _value, invalidate: true));
    if (!canUndo) return;
    final snapshot = _undoStack.removeLast();
    _redoStack.add(_DocumentSnapshot(_value, origin: snapshot.origin));
    _restore(snapshot.value);
  }

  /// Restores the next undone editing state; otherwise a no-op.
  void redo() {
    mutations.emit(MarkdownDocumentMutation(_value, _value, invalidate: true));
    if (!canRedo) return;
    final snapshot = _redoStack.removeLast();
    _undoStack.add(_DocumentSnapshot(_value, origin: snapshot.origin));
    _restore(snapshot.value);
  }

  void _recordUndo({required Object? origin, required bool mergeWithPrevious}) {
    final mergesWithPrevious =
        mergeWithPrevious &&
        origin != null &&
        _undoStack.isNotEmpty &&
        _undoStack.last.origin == origin;
    if (!mergesWithPrevious) {
      _undoStack.add(_DocumentSnapshot(_value, origin: origin));
      if (_undoStack.length > 200) _undoStack.removeAt(0);
    }
    _redoStack.clear();
  }

  void _restore(TextEditingValue value) {
    final previous = _value;
    _value = value;
    _revision++;
    mutations.emit(MarkdownDocumentMutation(previous, value, invalidate: true));
    notifyListeners();
  }

  @override
  void dispose() {
    _eraseDocument();
    mutations.emit(MarkdownDocumentMutation(_value, _value, invalidate: true));
    mutations.clear();
    super.dispose();
  }

  /// Releases document text, selection, composition, annotations and history.
  ///
  /// Unlike assigning an empty [text], this cannot be undone. Owners of private
  /// documents should call this synchronously before locking or navigating away.
  /// Dart strings cannot be zeroed in memory; this releases this controller's
  /// references and invalidates pending editor operations, not external copies.
  void wipe() {
    _eraseDocument();
    mutations.emit(MarkdownDocumentMutation(_value, _value, invalidate: true));
    notifyListeners();
  }

  void _eraseDocument() {
    _value = const TextEditingValue(
      selection: TextSelection.collapsed(offset: 0),
    );
    _undoStack.clear();
    _redoStack.clear();
    _annotations = const [];
    _revision++;
  }

  static TextEditingValue _normalizeValue(TextEditingValue value) {
    final length = value.text.length;
    return TextEditingValue(
      text: value.text,
      selection: _clampSelection(value.selection, length),
      composing: _clampComposing(value.composing, length),
    );
  }

  static TextSelection _clampSelection(TextSelection selection, int length) {
    return TextSelection(
      baseOffset: selection.baseOffset.clamp(0, length),
      extentOffset: selection.extentOffset.clamp(0, length),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  static TextRange _clampComposing(TextRange composing, int length) {
    if (!composing.isValid || !composing.isNormalized) {
      return TextRange.empty;
    }
    return TextRange(
      start: composing.start.clamp(0, length),
      end: composing.end.clamp(0, length),
    );
  }
}

class _DocumentSnapshot {
  const _DocumentSnapshot(this.value, {required this.origin});

  final TextEditingValue value;
  final Object? origin;
}
