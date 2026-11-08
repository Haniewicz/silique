import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'desktop_text_context_menu.dart';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'document_markdown_editing_controller.dart';
import 'live_markdown_annotation.dart';
import 'live_markdown_theme.dart';
import 'live_markdown_controller.dart';
import 'live_markdown_paste.dart';
import 'live_markdown_media.dart';
import 'markdown_paste_controller.dart';
import 'markdown_paste_region.dart';
import 'markdown_block.dart';
import 'markdown_block_parser.dart';
import 'markdown_editing_commands.dart';
import 'markdown_document_mutation.dart';
import 'markdown_syntax_tree.dart';
import 'markdown_table.dart';
import 'markdown_input_privacy.dart';
import 'text_selection_edge_auto_scroll.dart';

export 'document_markdown_editing_controller.dart'
    show
        LiveMarkdownImageResolver,
        LiveMarkdownVideoBuilder,
        LiveMarkdownAudioBuilder,
        defaultLiveMarkdownImageResolver,
        isMarkdownVideoDestination,
        isMarkdownAudioDestination;

/// Receives a Markdown link destination and its label; does not open a URL.
typedef LiveMarkdownLinkTap = void Function(String destination, String label);

/// Receives a Wiki target and optional alias (null when no alias is present).
typedef LiveMarkdownWikiLinkTap = void Function(String target, String? alias);

/// Receives an image destination and its Markdown alt text.
typedef LiveMarkdownImageTap = void Function(String destination, String alt);

/// Receives a video destination and its Markdown alt text.
typedef LiveMarkdownVideoTap = void Function(String destination, String alt);

/// Receives an audio destination and its Markdown alt text.
typedef LiveMarkdownAudioTap = void Function(String destination, String alt);

/// Reports the task marker's UTF-16 source range and its new checked state.
typedef LiveMarkdownTaskToggle = void Function(
  SourceRange taskMarkerRange,
  bool checked,
);

/// A lossless, document-level Markdown Live Preview editor.
///
/// The editor keeps one [TextEditingValue] and one native input connection for
/// the entire document. Markdown rendering is projected onto exact source
/// ranges. Interactive projections such as links and task checkboxes handle a
/// pointer click, while arrow-key traversal into the same range reveals its
/// source without replacing the editing surface.
///
/// Give the editor bounded space (for example, a Scaffold body or Expanded
/// inside a Column). Its owner must dispose [controller]. Persistence, link
/// navigation, and audio/video playback are application responsibilities.
class LiveMarkdownEditor extends StatefulWidget {
  /// Creates an editor backed by [controller]; callbacks and players are optional.
  const LiveMarkdownEditor({
    required this.controller,
    super.key,
    this.syntaxParser = const MarkdownSyntaxParser(),
    this.parser = const MarkdownBlockParser(),
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
    this.theme,
    this.editorDecoration,
    this.scrollController,
    this.onChanged,
    this.onLinkTap,
    this.onWikiLinkTap,
    this.onImageTap,
    this.onVideoTap,
    this.onAudioTap,
    this.onTaskToggle,
    this.imageResolver = defaultLiveMarkdownImageResolver,
    this.videoBuilder,
    this.audioBuilder,
    this.pasteConfiguration,
    this.mediaTypeResolver,
    this.autofocus = false,
    this.contentSizedField = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.readOnly = false,
    this.enableIMEPersonalizedLearning = true,
  });

  /// Source, selection, composition, and undo history. Not disposed by this widget.
  final LiveMarkdownController controller;

  /// Scanner used to project complete inline syntax and physical source lines.
  final MarkdownSyntaxParser syntaxParser;

  /// Block scanner used for complex-block layout and table interactions.
  /// [syntaxParser] supplies the inline source-position tree.
  final MarkdownBlockParser parser;

  /// Field grows with its Markdown instead of filling a viewport it scrolls
  /// itself. Use inside an existing document scroll view (e.g. NestedScrollView)
  /// so only that document scrollable owns the offset: sharing one controller
  /// between the document viewport and the field resets the document while the
  /// user types.
  final bool contentSizedField;

  /// Whether the platform may correct typed text; disable for private
  /// documents, together with [enableSuggestions] and
  /// [enableIMEPersonalizedLearning].
  final bool autocorrect;

  /// Whether the keyboard may suggest text; disable for private documents.
  final bool enableSuggestions;

  /// Prevents mutations in the main field and embedded table/callout fields.
  final bool readOnly;

  /// Whether the input method may learn from this document.
  final bool enableIMEPersonalizedLearning;

  /// Insets around the editing surface; defaults to 20 horizontal, 16 vertical.
  final EdgeInsetsGeometry padding;

  /// Input decoration for the underlying field; defaults to no border.
  final InputDecoration? editorDecoration;

  /// Partial semantic styles over the host's LiveMarkdownThemeData extension.
  /// TextStyle and appearance fields merge property by property.
  /// An omitted theme uses the host-adaptive Openbox defaults.
  final LiveMarkdownThemeData? theme;

  /// Optional caller-owned scroll controller. When omitted, one is owned here.
  final ScrollController? scrollController;

  /// Reports changed Markdown, including programmatic controller changes and
  /// undo/redo while attached. Not called for initial text or selection-only
  /// changes. Does not persist data; avoid feeding changes back in a loop.
  final ValueChanged<String>? onChanged;

  /// Handles rendered link taps. Validate destinations and navigate in your app.
  /// Arrow-key source traversal does not invoke this callback.
  final LiveMarkdownLinkTap? onLinkTap;

  /// Handles rendered Wiki-link taps; the application resolves the note target.
  final LiveMarkdownWikiLinkTap? onWikiLinkTap;

  /// Invoked when a rendered picture is clicked, before any caret placement.
  final LiveMarkdownImageTap? onImageTap;

  /// Invoked when a rendered video embed is clicked, before any caret
  /// placement.
  final LiveMarkdownVideoTap? onVideoTap;

  /// Invoked when a rendered audio embed is clicked, before any caret
  /// placement.
  final LiveMarkdownAudioTap? onAudioTap;

  /// Optional notification after a checkbox changes the source. Do not toggle
  /// it again here; the editor already applies the change to [controller].
  final LiveMarkdownTaskToggle? onTaskToggle;

  /// Resolves an image destination to the [ImageProvider] used by rendered
  /// inline pictures. Defaults to [defaultLiveMarkdownImageResolver], which
  /// maps `asset:` destinations to the application bundle and everything else
  /// to [NetworkImage].
  final LiveMarkdownImageResolver imageResolver;

  /// Builds the widget for a rendered video embed. When omitted, a non-playing
  /// placeholder is shown so applications can inject a real player.
  final LiveMarkdownVideoBuilder? videoBuilder;

  /// Builds the widget for a rendered audio embed. When omitted, a non-playing
  /// placeholder is shown so applications can inject a real player.
  final LiveMarkdownAudioBuilder? audioBuilder;

  /// Optional clipboard image import. The host saves/uploads media and returns
  /// a destination; the editor owns source insertion, selection, and undo.
  final LiveMarkdownPasteConfiguration? pasteConfiguration;

  /// Optional application attachment metadata, including extensionless URLs.
  /// Returning null falls back to filename extensions. Persist this metadata
  /// in the application so reloaded documents retain their media types.
  final LiveMarkdownMediaTypeResolver? mediaTypeResolver;

  /// Whether to request editing focus automatically; defaults to false.
  final bool autofocus;

  @override
  State<LiveMarkdownEditor> createState() => _LiveMarkdownEditorState();
}

class _LiveMarkdownEditorState extends State<LiveMarkdownEditor>
    with WidgetsBindingObserver {
  static const double _mouseSelectionSlop = kPrecisePointerPanSlop * 4;

  final GlobalKey _editorStackKey = GlobalKey();
  late DocumentMarkdownEditingController _textController;
  List<LiveMarkdownAnnotation> _lastAnnotations = const [];
  late final FocusNode _focusNode;
  late final ScrollController _ownedScrollController;
  bool _syncingDocument = false;
  String? _lastReportedText;
  DateTime? _lastTypingEdit;
  double _caretHeight = 0;
  int? _renderedCalloutStart;
  int? _pointerProtectedCalloutStart;
  int _calloutPointerGeneration = 0;
  int? _renderedTableStart;
  int? _sourceEditingTableStart;
  int? _pointerProtectedTableStart;
  int _pointerProtectionGeneration = 0;
  List<({int start, Rect rect})> _codeBackgrounds = const [];
  double _codeBackgroundScrollOffset = 0;
  bool _codeBackgroundMeasureScheduled = false;
  bool _snappingCaret = false;
  int? _mouseSelectionPointer;
  Offset? _mouseSelectionOrigin;
  ({
    int pointer,
    Offset origin,
    Duration time,
    MarkdownInlineNode node,
    LiveMarkdownController document,
    int revision,
  })?
  _linkPointer;
  bool _linkPointerMoved = false;
  DateTime _lastKeyTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  SourceRange? _keyboardActiveMediaRange;
  final Object _typingOrigin = Object();
  final Object _structuralOrigin = Object();
  final Object _taskOrigin = Object();
  bool _normalizingIme = false;
  bool _taskPointerActive = false;
  int _taskPointerGeneration = 0;
  bool _caretVisibilityScheduled = false;
  Size? _lastViewportSize;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _focusNode = FocusNode(onKeyEvent: _handleKeyEvent);
    _ownedScrollController = ScrollController();
    _createTextController();
    widget.controller.addListener(_handleDocumentChanged);
    _lastReportedText = widget.controller.text;
  }

  void _createTextController() {
    _textController = DocumentMarkdownEditingController(
      value: widget.controller.value,
      parser: widget.syntaxParser,
      blockParser: widget.parser,
    )..addListener(_handleLocalEditingValue);
  }

  /// Document viewport for measurement and edge scrolling. With
  /// [contentSizedField] it is never attached to the field itself.
  ScrollController get _effectiveScrollController =>
      widget.scrollController ?? _ownedScrollController;

  double get _currentScrollOffset => _effectiveScrollController.hasClients
      ? _effectiveScrollController.offset
      : 0;

  void _scheduleCodeBackgroundMeasure() {
    if (_codeBackgroundMeasureScheduled || !mounted) return;
    _codeBackgroundMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _codeBackgroundMeasureScheduled = false;
      if (mounted) {
        _alignCaretToGlyph();
        _measureCodeBackgrounds();
      }
    });
  }

  RenderEditable? _documentRenderEditable() {
    final stackObject = _editorStackKey.currentContext?.findRenderObject();
    RenderEditable? editable;
    void findEditable(RenderObject child) {
      if (editable == null &&
          child is RenderEditable &&
          child.plainText.length == _textController.text.length) {
        editable = child;
        return;
      }
      child.visitChildren(findEditable);
    }

    stackObject?.visitChildren(findEditable);
    return editable;
  }

  // Flutter centers a custom-height caret in the whole projected row. Mixed
  // heading/body metrics and inline widgets can move that center away from
  // the actual character. Align against the rendered glyph after layout.
  void _alignCaretToGlyph() {
    final editable = _documentRenderEditable();
    if (editable == null || !editable.hasSize) return;
    final selection = _textController.selection;
    final text = _textController.text;
    final caretOffset = selection.extentOffset;
    if (!selection.isValid ||
        text.isEmpty ||
        (caretOffset > 0 &&
            text[caretOffset - 1] == '\n' &&
            (caretOffset == text.length || text[caretOffset] == '\n'))) {
      editable.cursorOffset = Offset(editable.cursorOffset.dx, 0);
      return;
    }
    var offset = caretOffset.clamp(0, text.length - 1);
    if (text[offset] == '\n' && offset > 0) offset--;
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: offset, extentOffset: offset + 1),
    );
    if (boxes.isEmpty || boxes.first.toRect().height < 2) return;
    final caret = editable.getLocalRectForCaret(
      TextPosition(offset: selection.extentOffset),
    );
    final shift = boxes.first.toRect().center.dy - caret.center.dy;
    if (shift.abs() > caret.height * 0.75) {
      // A soft wrap can place the caret on the next row while the previous
      // source character still belongs to the preceding row.
      editable.cursorOffset = Offset(editable.cursorOffset.dx, 0);
      return;
    }
    if (shift.abs() > 0.25) {
      editable.cursorOffset += Offset(0, shift);
    }
  }

  void _measureCodeBackgrounds() {
    final stackObject = _editorStackKey.currentContext?.findRenderObject();
    if (stackObject is! RenderBox || !stackObject.hasSize) return;
    final documentEditable = _documentRenderEditable();
    if (documentEditable == null || !documentEditable.hasSize) return;
    final next = <({int start, Rect rect})>[];
    final blocks = _textController.blockParser.parse(_textController.text);
    for (final block in blocks) {
      if (block.type != MarkdownBlockType.codeFence ||
          block.sourceEnd <= block.sourceStart) {
        continue;
      }
      var finalCharacter = block.sourceEnd - 1;
      if (finalCharacter > block.sourceStart &&
          _textController.text.codeUnitAt(finalCharacter) >= 0xdc00 &&
          _textController.text.codeUnitAt(finalCharacter) <= 0xdfff) {
        finalCharacter--;
      }
      final firstBoxes = documentEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: block.sourceStart,
          extentOffset: block.sourceStart + 1,
        ),
      );
      // Silique: measure the block bottom against the last character's tight
      // boxes first; the final-line sweep below extends it when leads exist.
      final lastBoxes = documentEditable.getBoxesForSelection(
        TextSelection(
          baseOffset: finalCharacter,
          extentOffset: block.sourceEnd,
        ),
      );
      if (firstBoxes.isEmpty || lastBoxes.isEmpty) continue;
      // Silique: indented code-line leads are baseline placeholders whose box
      // covers the full line height, while tight text boxes stop at the glyph
      // descent. Measure the bottom across the whole final line (its lead and
      // the glyphs after it) so the panel always covers the painted glyphs of
      // that line once leads exist.
      var maxBottom = lastBoxes.last.bottom;
      var lastLineStart =
          _textController.text.lastIndexOf('\n', block.sourceEnd - 1) + 1;
      if (lastLineStart < block.sourceStart) lastLineStart = block.sourceStart;
      if (lastLineStart < finalCharacter) {
        for (final box in documentEditable.getBoxesForSelection(
          TextSelection(
            baseOffset: lastLineStart,
            extentOffset: finalCharacter,
          ),
        )) {
          if (box.bottom > maxBottom) maxBottom = box.bottom;
        }
      }
      final top = stackObject
          .globalToLocal(
            documentEditable.localToGlobal(Offset(0, firstBoxes.first.top - 1)),
          )
          .dy;
      final bottom = stackObject
          .globalToLocal(
            documentEditable.localToGlobal(Offset(0, maxBottom + 1)),
          )
          .dy;
      if (!top.isFinite || !bottom.isFinite || bottom <= top) continue;
      next.add((
        start: block.sourceStart,
        rect: Rect.fromLTRB(0, top, stackObject.size.width, bottom),
      ));
    }
    // A content-sized field paints its rects in content coordinates, so the
    // document viewport offset must not invalidate an unchanged measurement.
    final measuredScrollOffset = widget.contentSizedField
        ? 0.0
        : _currentScrollOffset;
    if (listEquals(_codeBackgrounds, next) &&
        (_codeBackgroundScrollOffset - measuredScrollOffset).abs() <= 0.25) {
      return;
    }
    setState(() {
      _codeBackgrounds = List.unmodifiable(next);
      _codeBackgroundScrollOffset = measuredScrollOffset;
    });
  }

  void _handleDocumentPointerDown(PointerDownEvent event) {
    // Observe taps without joining the native selection gesture arena.
    _linkPointer = null;
    _linkPointerMoved = false;
    _textController.holdLinkProjection = false;
    if (usesDesktopTextContextMenu &&
        event.buttons == kPrimaryButton &&
        !HardwareKeyboard.instance.isShiftPressed &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      final editable = _documentRenderEditable();
      if (editable != null) {
        final local = editable.globalToLocal(event.position);
        for (final node in _textController.renderedLinks) {
          final boxes = editable.getBoxesForSelection(
            TextSelection(
              baseOffset: node.contentRange.start,
              extentOffset: node.contentRange.end,
            ),
          );
          if (boxes.any((box) => box.toRect().contains(local))) {
            _linkPointer = (
              pointer: event.pointer,
              origin: event.position,
              time: event.timeStamp,
              node: node,
              document: widget.controller,
              revision: _textController.textRevision,
            );
            _textController.holdLinkProjection = true;
            break;
          }
        }
      }
    }
    final calloutStart = _renderedCalloutStart;
    if (calloutStart != null && !_calloutContainsGlobalPoint(event.position)) {
      _calloutPointerGeneration++;
      _pointerProtectedCalloutStart = null;
      setState(() => _renderedCalloutStart = null);
      _focusNode.requestFocus();
    }
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryButton ||
        _renderedTableStart != null) {
      return;
    }
    _mouseSelectionPointer = event.pointer;
    _mouseSelectionOrigin = event.position;
  }

  bool _calloutContainsGlobalPoint(Offset point) {
    final start = _renderedCalloutStart;
    if (start == null) return false;
    final editable = _documentRenderEditable();
    if (editable == null || !editable.hasSize) return false;
    final boxes = editable.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    if (boxes.isEmpty) return false;
    final box = boxes.first;
    final rect = Rect.fromPoints(
      editable.localToGlobal(Offset(box.left, box.top)),
      editable.localToGlobal(Offset(box.right, box.bottom)),
    );
    return rect.contains(point);
  }

  void _handleDocumentPointerCancel(PointerCancelEvent event) {
    _finishLinkPointer(event.pointer);
    if (_mouseSelectionPointer != event.pointer) return;
    _mouseSelectionPointer = null;
    _mouseSelectionOrigin = null;
  }

  void _handleDocumentPointerMove(PointerMoveEvent event) {
    final link = _linkPointer;
    if (link == null || link.pointer != event.pointer) return;
    final slop = event.kind == PointerDeviceKind.mouse
        ? kPrecisePointerPanSlop
        : kTouchSlop;
    if ((event.position - link.origin).distance > slop) {
      _linkPointerMoved = true;
    }
  }

  void _handleDocumentPointerUp(PointerUpEvent event) {
    final link = _linkPointer;
    if (link != null && link.pointer == event.pointer) {
      final tap =
          !_linkPointerMoved &&
          identical(link.document, widget.controller) &&
          link.revision == _textController.textRevision &&
          event.timeStamp - link.time < kLongPressTimeout;
      // Release after native onTapUp has set its caret, retaining the rendered
      // presentation for this frame just as a range retains its old layout.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _finishLinkPointer(event.pointer);
      });
      if (tap) _handleInlineInteraction(link.node);
      _mouseSelectionPointer = null;
      _mouseSelectionOrigin = null;
      return;
    }
    if (_mouseSelectionPointer != event.pointer) return;
    final origin = _mouseSelectionOrigin;
    _mouseSelectionPointer = null;
    _mouseSelectionOrigin = null;
    if (origin == null ||
        _renderedTableStart != null ||
        HardwareKeyboard.instance.isShiftPressed) {
      return;
    }
    final distance = (event.position - origin).distance;
    if (distance <= kPrecisePointerPanSlop ||
        distance > _mouseSelectionSlop ||
        _textController.selection.isCollapsed) {
      return;
    }
    final editable = _documentRenderEditable();
    if (editable == null || !editable.hasSize) return;
    final position = editable.getPositionForPoint(event.position);
    widget.controller.setSelection(
      TextSelection.collapsed(
        offset: position.offset,
        affinity: position.affinity,
      ),
    );
    _focusNode.requestFocus();
  }

  void _finishLinkPointer(int pointer) {
    if (_linkPointer?.pointer != pointer) return;
    _linkPointer = null;
    _textController.holdLinkProjection = false;
  }

  void _refreshCaretHeight() {
    final next = _textController.caretHeightAt(
      _textController.selection.extentOffset,
    );
    if ((next - _caretHeight).abs() <= 0.5 || !mounted) return;
    void update() => _caretHeight = next;

    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(update);
      });
    } else {
      setState(update);
    }
  }

  /// Pointer taps near a rendered picture can map inside its source range,
  /// revealing the image as source while the caret was never meant to enter
  /// it. A collapsed caret that lands strictly inside an image range without
  /// a recent key event snaps to the range end. Once arrow-key traversal has
  /// activated a media range, pointer placement inside its visible source is
  /// allowed until the caret leaves that activation range.
  void _snapCaretOutOfImageRanges() {
    if (_snappingCaret || !_focusNode.hasPrimaryFocus) return;
    final selection = _textController.selection;
    if (!selection.isCollapsed) return;
    final offset = selection.extentOffset;
    final images = _textController.syntaxTree.lines
        .expand((line) => _imageRanges(line.inlines))
        .toList(growable: false);
    final activeImages = images.where(
      (image) => _offsetInside(image.activationRange, offset),
    );
    final activeImage = activeImages.isEmpty ? null : activeImages.first;
    final recentKey =
        DateTime.now().difference(_lastKeyTimestamp) <
        const Duration(milliseconds: 250);
    if (recentKey && activeImage != null) {
      _keyboardActiveMediaRange = activeImage.activationRange;
      return;
    }

    final previousActive = _keyboardActiveMediaRange;
    if (previousActive != null &&
        activeImage != null &&
        _rangesOverlap(previousActive, activeImage.activationRange)) {
      _keyboardActiveMediaRange = activeImage.activationRange;
      return;
    }
    _keyboardActiveMediaRange = null;

    for (final image in images) {
      if (_offsetInside(image.range, offset)) {
        _snappingCaret = true;
        try {
          final snapped = _textController.value.copyWith(
            selection: TextSelection.collapsed(offset: image.escapeEnd),
          );
          _textController.value = snapped;
          widget.controller.setValue(snapped, addToHistory: false);
        } finally {
          _snappingCaret = false;
        }
        return;
      }
    }
  }

  bool _offsetInside(SourceRange range, int offset) =>
      offset > range.start && offset < range.end;

  bool _rangesOverlap(SourceRange first, SourceRange second) =>
      first.start < second.end && first.end > second.start;

  Iterable<({SourceRange range, SourceRange activationRange, int escapeEnd})>
  _imageRanges(
    Iterable<MarkdownInlineNode> nodes, {
    SourceRange? ancestorRange,
  }) sync* {
    for (final node in nodes) {
      final activationRange = ancestorRange ?? node.fullRange;
      if (node.kind == MarkdownInlineKind.image) {
        yield (
          range: node.fullRange,
          activationRange: activationRange,
          escapeEnd: activationRange.end,
        );
      }
      yield* _imageRanges(node.inlines, ancestorRange: activationRange);
    }
  }

  @override
  void didUpdateWidget(covariant LiveMarkdownEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleDocumentChanged);
      widget.controller.addListener(_handleDocumentChanged);
      _lastReportedText = widget.controller.text;
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.syntaxParser != widget.syntaxParser ||
        oldWidget.parser != widget.parser) {
      _textController.removeListener(_handleLocalEditingValue);
      _textController.dispose();
      _createTextController();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_handleDocumentChanged);
    _textController.removeListener(_handleLocalEditingValue);
    _textController.dispose();
    _focusNode.dispose();
    _ownedScrollController.dispose();
    super.dispose();
  }

  void _handleLocalEditingValue() {
    if (_normalizingIme) return;
    if (_taskPointerActive && _textController.text == widget.controller.text) {
      _syncingDocument = true;
      _textController.value = widget.controller.value;
      _syncingDocument = false;
      return;
    }
    final previous = widget.controller.value;
    final next = _textController.value;
    if (!_syncingDocument) {
      var normalized = _completeTypedTaskMarker(previous, next);
      if (normalized != next && _selectionInsideCodeFence()) normalized = next;
      // Software keyboards send an editing value instead of hardware Enter.
      if (previous.selection.isValid &&
          previous.selection.isCollapsed &&
          next.composing.isCollapsed &&
          next.selection.isCollapsed &&
          next.text ==
              previous.text.replaceRange(
                previous.selection.start,
                previous.selection.end,
                '\n',
              ) &&
          next.selection.extentOffset == previous.selection.start + 1 &&
          !_selectionInsideCodeFence(previous)) {
        normalized =
            applyMarkdownEditingCommand(
              previous,
              MarkdownEditingCommand.enter,
            ) ??
            next;
      }
      if (normalized != next) {
        _normalizingIme = true;
        _textController.value = normalized;
        _normalizingIme = false;
      }
    }
    _scheduleCaretVisibility();
    _scheduleCodeBackgroundMeasure();
    _refreshCaretHeight();
    _snapCaretOutOfImageRanges();
    if (_syncingDocument) return;
    final protectedCalloutStart =
        _pointerProtectedCalloutStart ?? _renderedCalloutStart;
    final activeCallout = protectedCalloutStart == null
        ? null
        : _currentCallout(protectedCalloutStart);
    final localSelection = _textController.selection;
    final calloutOwnsPointer = _pointerProtectedCalloutStart != null;
    if (activeCallout != null &&
        (calloutOwnsPointer ||
            (localSelection.isValid &&
                localSelection.start >= activeCallout.sourceStart &&
                localSelection.end <= activeCallout.sourceEnd))) {
      _syncingDocument = true;
      _textController.value = widget.controller.value;
      _syncingDocument = false;
      setState(() {});
      return;
    }
    final protectedTableStart =
        _pointerProtectedTableStart ?? _renderedTableStart;
    final activeTable = protectedTableStart == null
        ? null
        : _currentTable(protectedTableStart);
    if (activeTable != null &&
        localSelection.isValid &&
        localSelection.start >= activeTable.block.sourceStart &&
        localSelection.end <= activeTable.block.sourceEnd) {
      _syncingDocument = true;
      _textController.value = widget.controller.value;
      _syncingDocument = false;
      setState(() {});
      return;
    }
    _activateKeyboardTableSource();
    if (_textController.value == widget.controller.value) {
      return;
    }
    final textChanged = _textController.text != widget.controller.value.text;
    final now = DateTime.now();
    final mergeTyping =
        textChanged &&
        _lastTypingEdit != null &&
        now.difference(_lastTypingEdit!) < const Duration(milliseconds: 800);
    if (textChanged) _lastTypingEdit = now;

    _syncingDocument = true;
    widget.controller.applyEditingValue(
      _textController.value,
      origin: textChanged ? _typingOrigin : null,
      mergeWithPrevious: mergeTyping,
    );
    _syncingDocument = false;
  }

  // Complete only a freshly typed/pasted marker or committed IME input.
  // Opening a note, moving the caret, undo and deleting a separator do not
  // rewrite source. Keep completion in the same undo step as the typed `]`.
  TextEditingValue _completeTypedTaskMarker(
    TextEditingValue previous,
    TextEditingValue next,
  ) {
    if (!next.selection.isValid ||
        !next.selection.isCollapsed ||
        (next.composing.isValid && !next.composing.isCollapsed)) {
      return next;
    }
    final edit = MarkdownSourceEdit.fromEditingValues(previous, next);
    final compositionCommitted =
        previous.composing.isValid &&
        !previous.composing.isCollapsed &&
        next.composing.isCollapsed;
    if ((edit == null || edit.insertedLength == 0) && !compositionCommitted) {
      return next;
    }
    final caret = next.selection.extentOffset;
    final start = caret == 0 ? 0 : next.text.lastIndexOf('\n', caret - 1) + 1;
    final marker = RegExp(r'^[ \t]*[-+*][ \t]+\[[ xX]\]')
        .firstMatch(next.text.substring(start, caret));
    if (marker == null) return next;
    final separator = start + marker.end;
    if (separator < next.text.length &&
        (next.text[separator] == ' ' || next.text[separator] == '\t')) {
      return next;
    }
    // Also repair a missing separator when typing a label after an older bare
    // checkbox, or when a marker with text is pasted in one operation.
    return next.copyWith(
      text: next.text.replaceRange(separator, separator, ' '),
      selection: TextSelection.collapsed(offset: caret + 1),
      composing: TextRange.empty,
    );
  }

  void _activateKeyboardTableSource() {
    if (!_focusNode.hasFocus ||
        DateTime.now().difference(_lastKeyTimestamp) >=
            const Duration(milliseconds: 250)) {
      return;
    }
    final selection = _textController.selection;
    if (!selection.isValid || !selection.isCollapsed) return;
    for (final block in widget.parser.parse(_textController.text)) {
      if (block.type != MarkdownBlockType.table ||
          selection.extentOffset <= block.sourceStart ||
          selection.extentOffset >= block.sourceEnd) {
        continue;
      }
      if (_sourceEditingTableStart == block.sourceStart) return;
      setState(() {
        _renderedTableStart = block.sourceStart;
        _sourceEditingTableStart = block.sourceStart;
      });
      return;
    }
  }

  void _handleDocumentChanged() {
    _scheduleCaretVisibility();
    final annotations = widget.controller.annotations;
    if (!identical(annotations, _lastAnnotations)) {
      _lastAnnotations = annotations;
      if (mounted) setState(() {});
    }
    _textController.updateProjectionComposing(widget.controller.composing);
    _scheduleCodeBackgroundMeasure();
    _reconcileTableSourceSelection();
    final text = widget.controller.text;
    if (text != _lastReportedText) {
      _lastReportedText = text;
      widget.onChanged?.call(text);
    }
    if (_syncingDocument || _textController.value == widget.controller.value) {
      return;
    }
    _syncingDocument = true;
    _textController.value = widget.controller.value;
    _syncingDocument = false;
    _refreshCaretHeight();
    if (!widget.controller.selection.isCollapsed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        EditableTextState? state;
        void visit(Element element) {
          if (element is StatefulElement &&
              element.state is EditableTextState) {
            final candidate = element.state as EditableTextState;
            if (candidate.widget.controller == _textController) {
              state = candidate;
            }
          }
          element.visitChildren(visit);
        }

        (_editorStackKey.currentContext as Element?)?.visitChildren(visit);
        state?.bringIntoView(
          TextPosition(offset: widget.controller.selection.start),
        );
      });
    }
  }

  @override
  void didChangeMetrics() => _scheduleCaretVisibility();

  void _scheduleCaretVisibility() {
    if (_caretVisibilityScheduled || !mounted) return;
    _caretVisibilityScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _caretVisibilityScheduled = false;
      if (!mounted ||
          !_focusNode.hasFocus ||
          !_textController.selection.isValid ||
          !_textController.selection.isCollapsed) {
        return;
      }
      EditableTextState? state;
      void visit(Element element) {
        if (element is StatefulElement && element.state is EditableTextState) {
          final candidate = element.state as EditableTextState;
          if (candidate.widget.controller == _textController) state = candidate;
        }
        element.visitChildren(visit);
      }

      (_editorStackKey.currentContext as Element?)?.visitChildren(visit);
      state?.bringIntoView(
        TextPosition(offset: _textController.selection.extentOffset),
      );
    });
  }

  void _beginTaskPointer(MarkdownLineNode line) {
    _taskPointerGeneration++;
    _taskPointerActive = true;
  }

  void _endTaskPointer() {
    final generation = _taskPointerGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _taskPointerGeneration) {
        _taskPointerActive = false;
      }
    });
  }

  void _reconcileTableSourceSelection() {
    final tableStart = _sourceEditingTableStart;
    if (tableStart == null) return;
    final current = _currentTable(tableStart);
    final selection = widget.controller.selection;
    final inside =
        current != null &&
        selection.isValid &&
        selection.start >= current.block.sourceStart &&
        selection.end <= current.block.sourceEnd;
    if (inside) return;
    setState(() {
      _renderedTableStart = null;
      _sourceEditingTableStart = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    final navigationKey =
        event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown;
    if (event is KeyRepeatEvent) {
      if (navigationKey) _lastKeyTimestamp = DateTime.now();
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (navigationKey) {
      _lastKeyTimestamp = DateTime.now();
    }
    final keyboard = HardwareKeyboard.instance;
    final commandPressed = keyboard.isMetaPressed || keyboard.isControlPressed;
    final insideCodeFence = _selectionInsideCodeFence();

    if (commandPressed && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (keyboard.isShiftPressed) {
        widget.controller.redo();
      } else {
        widget.controller.undo();
      }
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.enter &&
        !commandPressed &&
        !insideCodeFence) {
      final command = keyboard.isShiftPressed
          ? MarkdownEditingCommand.shiftEnter
          : MarkdownEditingCommand.enter;
      final next = applyMarkdownEditingCommand(_textController.value, command);
      if (next != null) {
        _applyStructuralValue(next);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.backspace &&
        !commandPressed &&
        !insideCodeFence) {
      final next = applyMarkdownEditingCommand(
        _textController.value,
        MarkdownEditingCommand.backspace,
      );
      if (next != null) {
        _applyStructuralValue(next);
        return KeyEventResult.handled;
      }
    }

    if (event.logicalKey == LogicalKeyboardKey.tab && !commandPressed) {
      if (insideCodeFence) {
        final next = _applyCodeTab(
          _textController.value,
          outdent: keyboard.isShiftPressed,
        );
        _applyStructuralValue(next);
        return KeyEventResult.handled;
      }
      final command = keyboard.isShiftPressed
          ? MarkdownEditingCommand.shiftTab
          : MarkdownEditingCommand.tab;
      final next = applyMarkdownEditingCommand(_textController.value, command);
      if (next != null) {
        _applyStructuralValue(next);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  bool _selectionInsideCodeFence([TextEditingValue? editingValue]) {
    final value = editingValue ?? _textController.value;
    final selection = value.selection;
    if (!selection.isValid) return false;
    return _textController.blockParser.parse(value.text).any((block) {
      if (block.type != MarkdownBlockType.codeFence) return false;
      if (selection.isCollapsed) {
        return selection.extentOffset > block.sourceStart &&
            (selection.extentOffset < block.sourceEnd ||
                (selection.extentOffset == block.sourceEnd &&
                    block.sourceEnd == value.text.length));
      }
      return selection.start >= block.sourceStart &&
          selection.end <= block.sourceEnd;
    });
  }

  TextEditingValue _applyCodeTab(
    TextEditingValue value, {
    required bool outdent,
  }) {
    final selection = value.selection;
    if (!selection.isCollapsed) {
      if (outdent) return value.copyWith(composing: TextRange.empty);
      final selected = value.text.substring(selection.start, selection.end);
      final replacement = '  ${selected.replaceAll('\n', '\n  ')}';
      final text = value.text.replaceRange(
        selection.start,
        selection.end,
        replacement,
      );
      return value.copyWith(
        text: text,
        selection: TextSelection(
          baseOffset: selection.start,
          extentOffset: selection.start + replacement.length,
        ),
        composing: TextRange.empty,
      );
    }

    final caret = selection.extentOffset;
    if (!outdent) {
      final text = value.text.replaceRange(caret, caret, '  ');
      return value.copyWith(
        text: text,
        selection: TextSelection.collapsed(offset: caret + 2),
        composing: TextRange.empty,
      );
    }

    final lineStart = caret == 0
        ? 0
        : value.text.lastIndexOf('\n', caret - 1) + 1;
    var removeEnd = lineStart;
    if (removeEnd < value.text.length &&
        value.text.codeUnitAt(removeEnd) == 0x09) {
      removeEnd++;
    } else {
      while (removeEnd < value.text.length &&
          removeEnd < lineStart + 2 &&
          value.text.codeUnitAt(removeEnd) == 0x20) {
        removeEnd++;
      }
    }
    final removed = removeEnd - lineStart;
    if (removed == 0) return value.copyWith(composing: TextRange.empty);
    final text = value.text.replaceRange(lineStart, removeEnd, '');
    return value.copyWith(
      text: text,
      selection: TextSelection.collapsed(
        offset: caret > removeEnd ? caret - removed : lineStart,
      ),
      composing: TextRange.empty,
    );
  }

  void _applyStructuralValue(TextEditingValue value) {
    _lastTypingEdit = null;
    _syncingDocument = true;
    _textController.value = value;
    widget.controller.setValue(value, origin: _structuralOrigin);
    _syncingDocument = false;
    _refreshCaretHeight();
  }

  void _handleInlineInteraction(MarkdownInlineNode node) {
    final tree = _textController.syntaxTree;
    if (node.kind == MarkdownInlineKind.link) {
      final destination = node.destinationRange == null
          ? ''
          : unescapeMarkdownMedia(tree.textOf(node.destinationRange!));
      widget.onLinkTap?.call(destination, tree.textOf(node.contentRange));
      return;
    }
    if (node.kind == MarkdownInlineKind.wikiLink) {
      final target = node.targetRange == null
          ? tree.textOf(node.contentRange)
          : tree.textOf(node.targetRange!);
      final alias = node.aliasRange == null
          ? null
          : tree.textOf(node.aliasRange!);
      widget.onWikiLinkTap?.call(target, alias);
      return;
    }
    if (node.kind == MarkdownInlineKind.image) {
      final destination = node.destinationRange == null
          ? ''
          : unescapeMarkdownMedia(tree.textOf(node.destinationRange!));
      final alt = unescapeMarkdownMedia(tree.textOf(node.contentRange));
      if (resolveLiveMarkdownMediaType(
            destination,
            resolver: widget.mediaTypeResolver,
          ) ==
          LiveMarkdownMediaType.video) {
        widget.onVideoTap?.call(destination, alt);
      } else if (resolveLiveMarkdownMediaType(
            destination,
            resolver: widget.mediaTypeResolver,
          ) ==
          LiveMarkdownMediaType.audio) {
        widget.onAudioTap?.call(destination, alt);
      } else {
        widget.onImageTap?.call(destination, alt);
      }
    }
  }

  void _handleTaskInteraction(MarkdownLineNode line) {
    _taskPointerActive = false;
    _taskPointerGeneration++;
    final marker = line.taskMarkerRange;
    if (marker == null || marker.length < 3) return;
    final stateOffset = marker.start + 1;
    if (stateOffset < 0 || stateOffset >= widget.controller.text.length) return;
    final currentState = widget.controller.text.codeUnitAt(stateOffset);
    if (currentState != 0x20 && currentState != 0x78 && currentState != 0x58) {
      return;
    }
    final checked = currentState != 0x78 && currentState != 0x58;
    final nextText = widget.controller.text.replaceRange(
      stateOffset,
      stateOffset + 1,
      checked ? 'x' : ' ',
    );
    final nextValue = widget.controller.value.copyWith(
      text: nextText,
      selection: widget.controller.selection,
      composing: TextRange.empty,
    );
    _lastTypingEdit = null;
    widget.controller.setValue(nextValue, origin: _taskOrigin);
    widget.onTaskToggle?.call(marker, checked);
    _focusNode.requestFocus();
  }

  void _handleBlockInteraction(MarkdownBlock block) {
    final offset = block.sourceEnd > block.sourceStart
        ? block.sourceStart + 1
        : block.sourceStart;
    widget.controller.setSelection(TextSelection.collapsed(offset: offset));
    _focusNode.requestFocus();
  }

  void _handleCalloutEditingInteraction(
    MarkdownBlock block,
    CalloutEditingField field,
    int localOffset,
  ) {
    final current = _currentCallout(block.sourceStart);
    if (current == null) return;
    final parts = CalloutSourceParts.parse(current);
    final documentOffset = field == CalloutEditingField.title
        ? parts.titleStart + localOffset.clamp(0, parts.title.length)
        : parts.bodyDocumentOffset(localOffset);
    if (_renderedCalloutStart != block.sourceStart) {
      setState(() => _renderedCalloutStart = block.sourceStart);
    }
    widget.controller.setValue(
      widget.controller.value.copyWith(
        selection: TextSelection.collapsed(offset: documentOffset),
        composing: TextRange.empty,
      ),
      addToHistory: false,
    );
  }

  void _handleCalloutPointerDown(MarkdownBlock block) {
    _pointerProtectedCalloutStart = block.sourceStart;
    _calloutPointerGeneration++;
  }

  void _handleCalloutPointerUp(MarkdownBlock block) {
    final generation = _calloutPointerGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _calloutPointerGeneration == generation &&
            _pointerProtectedCalloutStart == block.sourceStart) {
          _pointerProtectedCalloutStart = null;
        }
      });
    });
  }

  void _handleCalloutEditInteraction(
    MarkdownBlock block,
    CalloutEditingField field,
    TextEditingValue localValue,
    Object editOrigin,
  ) {
    final current = _currentCallout(block.sourceStart);
    if (current == null) return;
    final parts = CalloutSourceParts.parse(current);
    late final String nextText;
    late final TextEditingValue nextValue;
    if (field == CalloutEditingField.title) {
      nextText = widget.controller.text.replaceRange(
        parts.titleStart,
        parts.titleEnd,
        localValue.text,
      );
      nextValue = _offsetEditingValue(
        localValue,
        text: nextText,
        offset: parts.titleStart,
      );
    } else {
      final rawBody = widget.controller.text.substring(
        parts.bodyStart,
        current.sourceEnd,
      );
      final oldLines = rawBody.split('\n');
      final prefixes = oldLines
          .map((line) => RegExp(r'^\s*>\s?').firstMatch(line)?.group(0) ?? '> ')
          .toList(growable: false);
      final newLines = localValue.text.split('\n');
      final mappedStarts = <int>[];
      var cursor = parts.bodyStart;
      final replacement = <String>[];
      for (var index = 0; index < newLines.length; index++) {
        final prefix = index < prefixes.length
            ? prefixes[index]
            : prefixes.isEmpty
            ? '> '
            : prefixes.last;
        replacement.add('$prefix${newLines[index]}');
        mappedStarts.add(cursor + prefix.length);
        cursor += prefix.length + newLines[index].length + 1;
      }
      final bodySource = replacement.join('\n');
      nextText = widget.controller.text.replaceRange(
        parts.bodyStart,
        current.sourceEnd,
        bodySource,
      );
      int mapOffset(int offset) {
        final before = localValue.text.substring(
          0,
          offset.clamp(0, localValue.text.length),
        );
        final line = '\n'.allMatches(before).length;
        return mappedStarts[line.clamp(0, mappedStarts.length - 1)] +
            before.length -
            (before.lastIndexOf('\n') + 1);
      }

      final selection = localValue.selection;
      final composing = localValue.composing;
      nextValue = TextEditingValue(
        text: nextText,
        selection: TextSelection(
          baseOffset: mapOffset(selection.baseOffset),
          extentOffset: mapOffset(selection.extentOffset),
          affinity: selection.affinity,
          isDirectional: selection.isDirectional,
        ),
        composing: composing.isValid && composing.isNormalized
            ? TextRange(
                start: mapOffset(composing.start),
                end: mapOffset(composing.end),
              )
            : TextRange.empty,
      );
    }
    widget.controller.applyEditingValue(
      nextValue,
      origin: editOrigin,
      mergeWithPrevious: true,
    );
  }

  void _handleCalloutSourceInteraction(
    MarkdownBlock block,
    int documentOffset,
  ) {
    if (_renderedCalloutStart != null) {
      setState(() => _renderedCalloutStart = null);
    }
    widget.controller.setValue(
      widget.controller.value.copyWith(
        selection: TextSelection.collapsed(offset: documentOffset),
        composing: TextRange.empty,
      ),
      addToHistory: false,
    );
    _focusNode.requestFocus();
  }

  MarkdownBlock? _currentCallout(int start) {
    for (final candidate in widget.parser.parse(widget.controller.text)) {
      if (candidate.type == MarkdownBlockType.callout &&
          candidate.sourceStart == start) {
        return candidate;
      }
    }
    return null;
  }

  void _handleTableEditingInteraction(
    MarkdownBlock block,
    int rowIndex,
    int column,
    TextPosition position,
  ) {
    final current = _currentTable(block.sourceStart);
    if (current == null || rowIndex >= current.table.rows.length) return;
    final row = current.table.rows[rowIndex];
    if (column >= row.cells.length) return;
    _lastTypingEdit = null;
    _sourceEditingTableStart = null;
    if (_renderedTableStart != block.sourceStart) {
      setState(() => _renderedTableStart = block.sourceStart);
    }
    final cell = row.cells[column];
    final contentLength = cell.contentEnd - cell.contentStart;
    final documentOffset = contentLength == 0
        ? cell.editingOffset
        : cell.contentStart + position.offset.clamp(0, contentLength);
    widget.controller.setValue(
      widget.controller.value.copyWith(
        selection: TextSelection.collapsed(
          offset: documentOffset,
          affinity: position.affinity,
        ),
        composing: TextRange.empty,
      ),
      addToHistory: false,
    );
  }

  void _handleTablePointerDown(MarkdownBlock block) {
    _pointerProtectedTableStart = block.sourceStart;
    _pointerProtectionGeneration++;
  }

  void _handleTablePointerUp(MarkdownBlock block) {
    final generation = _pointerProtectionGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          _pointerProtectionGeneration == generation &&
          _pointerProtectedTableStart == block.sourceStart) {
        _pointerProtectedTableStart = null;
      }
    });
  }

  bool _handleTableCellEditInteraction(
    MarkdownBlock block,
    int rowIndex,
    int column,
    TextEditingValue localValue,
    Object editOrigin,
    bool textChanged,
  ) {
    final current = _currentTable(block.sourceStart);
    if (current == null || rowIndex >= current.table.rows.length) return false;
    final row = current.table.rows[rowIndex];
    if (column >= row.cells.length) return false;
    final cell = row.cells[column];
    final rawCell = widget.controller.text.substring(cell.start, cell.end);
    final canonicalEcho = rawCell == ' ${localValue.text} ';
    final valueStart = textChanged || canonicalEcho
        ? cell.start + 1
        : cell.contentStart == cell.contentEnd
        ? cell.editingOffset
        : cell.contentStart;
    final nextText = textChanged
        ? widget.controller.text.replaceRange(
            cell.start,
            cell.end,
            ' ${localValue.text} ',
          )
        : widget.controller.text;
    _lastTypingEdit = null;
    widget.controller.applyEditingValue(
      _offsetEditingValue(localValue, text: nextText, offset: valueStart),
      origin: editOrigin,
      mergeWithPrevious: true,
    );
    return _currentTable(block.sourceStart) != null;
  }

  bool _handleTableSourceEditInteraction(
    MarkdownBlock block,
    TextEditingValue localValue,
    Object editOrigin,
  ) {
    final current = _currentTable(block.sourceStart);
    if (current == null) return false;
    final nextText = widget.controller.text.replaceRange(
      current.block.sourceStart,
      current.block.sourceEnd,
      localValue.text,
    );
    _lastTypingEdit = null;
    widget.controller.applyEditingValue(
      _offsetEditingValue(
        localValue,
        text: nextText,
        offset: current.block.sourceStart,
      ),
      origin: editOrigin,
      mergeWithPrevious: true,
    );
    final valid = _currentTable(block.sourceStart) != null;
    if (!valid && mounted) {
      setState(() {
        _renderedTableStart = null;
        _sourceEditingTableStart = null;
      });
      _focusNode.requestFocus();
    }
    return valid;
  }

  TextEditingValue _offsetEditingValue(
    TextEditingValue localValue, {
    required String text,
    required int offset,
  }) {
    final length = localValue.text.length;
    final localSelection = localValue.selection;
    final localComposing = localValue.composing;
    return TextEditingValue(
      text: text,
      selection: TextSelection(
        baseOffset: offset + localSelection.baseOffset.clamp(0, length),
        extentOffset: offset + localSelection.extentOffset.clamp(0, length),
        affinity: localSelection.affinity,
        isDirectional: localSelection.isDirectional,
      ),
      composing: localComposing.isValid && localComposing.isNormalized
          ? TextRange(
              start: offset + localComposing.start.clamp(0, length),
              end: offset + localComposing.end.clamp(0, length),
            )
          : TextRange.empty,
    );
  }

  ({int rowIndex, int column})? _handleTableStructureInteraction(
    MarkdownBlock block,
    int rowIndex,
    int column,
    MarkdownEditingCommand command,
  ) {
    final current = _currentTable(block.sourceStart);
    if (current == null || rowIndex >= current.table.rows.length) return null;
    final row = current.table.rows[rowIndex];
    final columnCommand =
        command == MarkdownEditingCommand.tableInsertColumnLeft ||
        command == MarkdownEditingCommand.tableInsertColumnRight ||
        command == MarkdownEditingCommand.tableDeleteColumn;
    final cell = column < row.cells.length
        ? row.cells[column]
        : columnCommand && column < current.table.rows.first.cells.length
        ? current.table.rows.first.cells[column]
        : row.cells.isNotEmpty
        ? row.cells.last
        : null;
    if (cell == null) return null;
    final prepared = _textController.value.copyWith(
      selection: TextSelection.collapsed(offset: cell.editingOffset),
      composing: TextRange.empty,
    );
    final next = applyMarkdownEditingCommand(prepared, command);
    if (next == null) return null;
    if (_renderedTableStart != block.sourceStart) {
      setState(() => _renderedTableStart = block.sourceStart);
    }
    _sourceEditingTableStart = null;
    _applyStructuralValue(next);
    return _tableTargetAt(block.sourceStart, next.selection.extentOffset);
  }

  ({int rowIndex, int column})? _handleTableMaterializeInteraction(
    MarkdownBlock block,
    int rowIndex,
    int column,
  ) {
    final next = materializeMarkdownTableCell(
      _textController.value,
      tableStart: block.sourceStart,
      rowIndex: rowIndex,
      column: column,
    );
    if (next == null) return null;
    if (_renderedTableStart != block.sourceStart) {
      setState(() => _renderedTableStart = block.sourceStart);
    }
    _sourceEditingTableStart = null;
    _applyStructuralValue(next);
    return _tableTargetAt(block.sourceStart, next.selection.extentOffset);
  }

  void _handleTableHistoryInteraction({required bool redo}) {
    if (redo) {
      widget.controller.redo();
    } else {
      widget.controller.undo();
    }
  }

  void _handleTableExitInteraction(int documentOffset) {
    if (_renderedTableStart != null || _sourceEditingTableStart != null) {
      setState(() {
        _renderedTableStart = null;
        _sourceEditingTableStart = null;
      });
    }
    widget.controller.setValue(
      widget.controller.value.copyWith(
        selection: TextSelection.collapsed(offset: documentOffset),
        composing: TextRange.empty,
      ),
      addToHistory: false,
    );
    _focusNode.requestFocus();
  }

  ({MarkdownBlock block, MarkdownTableSource table})? _currentTable(
    int tableStart,
  ) {
    for (final candidate in widget.parser.parse(widget.controller.text)) {
      if (candidate.type != MarkdownBlockType.table ||
          candidate.sourceStart != tableStart) {
        continue;
      }
      final table = MarkdownTableSource.fromBlock(
        widget.controller.text,
        candidate,
      );
      if (table != null) return (block: candidate, table: table);
    }
    return null;
  }

  ({int rowIndex, int column})? _tableTargetAt(int tableStart, int offset) {
    final current = _currentTable(tableStart);
    final location = current?.table.locationAt(offset);
    if (location == null) return null;
    return (rowIndex: location.rowIndex, column: location.column);
  }

  @override
  Widget build(BuildContext context) => MarkdownInputPrivacy(
    readOnly: widget.readOnly,
    autocorrect: widget.autocorrect,
    enableSuggestions: widget.enableSuggestions,
    enableIMEPersonalizedLearning: widget.enableIMEPersonalizedLearning,
    child: IgnorePointer(
      ignoring: widget.readOnly,
      child: Builder(builder: _buildEditor),
    ),
  );

  Widget _buildEditor(BuildContext context) {
    final theme = Theme.of(context);
    final presentation = ResolvedLiveMarkdownTheme(
      host: theme,
      theme: widget.theme,
    );
    final appearance = presentation.paint;
    final baseStyle = presentation.bodyStyle;
    final styleSheet = presentation.styleSheet;
    final headingStyles = presentation.headingStyles;
    return MarkdownPasteScope(
      controller: widget.controller,
      configuration: widget.pasteConfiguration,
      child: Padding(
        padding: widget.padding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            if (_lastViewportSize != size) {
              _lastViewportSize = size;
              _scheduleCaretVisibility();
            }
            _textController.updatePresentation(
              baseStyle: baseStyle,
              headingStyles: headingStyles,
              appearance: appearance,
              linkColor: styleSheet.a?.color ?? theme.colorScheme.primary,
              codeBackgroundColor:
                  styleSheet.code?.backgroundColor ??
                  theme.colorScheme.surfaceContainerHighest,
              markdownStyleSheet: styleSheet,
              contentWidth: constraints.maxWidth,
              onInlineInteraction: _handleInlineInteraction,
              onTaskInteraction: _handleTaskInteraction,
              onTaskPointerDown: _beginTaskPointer,
              onTaskPointerUp: _endTaskPointer,
              onBlockInteraction: _handleBlockInteraction,
              calloutInteractions: (
                beginPointer: _handleCalloutPointerDown,
                endPointer: _handleCalloutPointerUp,
                startEditing: _handleCalloutEditingInteraction,
                edit: _handleCalloutEditInteraction,
                revealSource: _handleCalloutSourceInteraction,
              ),
              tableInteractions: (
                beginPointer: _handleTablePointerDown,
                endPointer: _handleTablePointerUp,
                startEditing: _handleTableEditingInteraction,
                editCell: _handleTableCellEditInteraction,
                editSource: _handleTableSourceEditInteraction,
                runCommand: _handleTableStructureInteraction,
                materializeCell: _handleTableMaterializeInteraction,
                history: _handleTableHistoryInteraction,
                exit: _handleTableExitInteraction,
              ),
              renderedCalloutStart: _renderedCalloutStart,
              renderedTableStart: _renderedTableStart,
              sourceEditingTableStart: _sourceEditingTableStart,
              projectionComposing: widget.controller.composing,
              imageResolver: widget.imageResolver,
              mediaTypeResolver: widget.mediaTypeResolver,
              videoBuilder: widget.videoBuilder,
              audioBuilder: widget.audioBuilder,
              textScaler: MediaQuery.textScalerOf(context),
              annotations: widget.controller.annotations,
            );
            // The presentation values are ready only after the update above, so
            // the caret height is computed here and re-evaluated whenever the
            // listener requests a rebuild.
            _caretHeight = _textController.caretHeightAt(
              _textController.selection.extentOffset,
            );
            _scheduleCodeBackgroundMeasure();
            final codeDecoration =
                styleSheet.codeblockDecoration ??
                BoxDecoration(
                  color:
                      styleSheet.code?.backgroundColor ??
                      theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                );
            final codeLayerChildren = <Widget>[
              for (final background in _codeBackgrounds)
                Positioned.fromRect(
                  rect: background.rect,
                  child: DecoratedBox(
                    key: ValueKey('code-background-${background.start}'),
                    decoration: codeDecoration,
                  ),
                ),
            ];
            // A content-sized field never scrolls itself: its measured rects
            // are content coordinates, so the layer paints without scroll
            // compensation. A bounded field scrolls its own text, so its layer
            // follows the offset until the next measurement.
            final codeLayer = IgnorePointer(
              child: widget.contentSizedField
                  ? Stack(
                      key: const ValueKey('code-background-layer'),
                      fit: StackFit.passthrough,
                      clipBehavior: Clip.none,
                      children: codeLayerChildren,
                    )
                  : AnimatedBuilder(
                      animation: _effectiveScrollController,
                      child: Stack(
                        key: const ValueKey('code-background-layer'),
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: codeLayerChildren,
                      ),
                      builder: (context, child) => Transform.translate(
                        offset: Offset(
                          0,
                          _codeBackgroundScrollOffset - _currentScrollOffset,
                        ),
                        child: child,
                      ),
                    ),
            );
            final editor = Builder(
              builder: (context) => Stack(
                key: _editorStackKey,
                fit: widget.contentSizedField
                    ? StackFit.passthrough
                    : StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  if (widget.contentSizedField)
                    Positioned.fill(child: codeLayer)
                  else
                    codeLayer,
                  DefaultSelectionStyle(
                    selectionColor: _renderedCalloutStart == null
                        ? Theme.of(context).textSelectionTheme.selectionColor ??
                              theme.colorScheme.primary.withValues(alpha: 0.28)
                        : Colors.transparent,
                    cursorColor:
                        Theme.of(context).textSelectionTheme.cursorColor ??
                        theme.colorScheme.primary,
                    child: MarkdownPasteRegion(
                      toDocumentOffset: (offset) => offset,
                      field: TextField(
                        readOnly: widget.readOnly,
                        key: const ValueKey('livemd-document-field'),
                        selectionControls:
                            TextSelectionEdgeAutoScroll.controlsOf(context),
                        contextMenuBuilder: markdownPasteContextMenu,
                        controller: _textController,
                        contentInsertionConfiguration:
                            markdownContentInsertionConfiguration(
                              context,
                              _textController,
                            ),
                        focusNode: _focusNode,
                        autofocus: widget.autofocus,
                        expands: !widget.contentSizedField,
                        minLines: widget.contentSizedField ? 1 : null,
                        maxLines: null,
                        scrollController: widget.contentSizedField
                            ? null
                            : _effectiveScrollController,
                        // A content-sized field must hand vertical drags to the
                        // document scroll view that owns it.
                        scrollPhysics: widget.contentSizedField
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        keyboardType: TextInputType.multiline,
                        textInputAction: TextInputAction.newline,
                        scrollPadding: const EdgeInsets.all(40),
                        textAlignVertical: TextAlignVertical.top,
                        style: baseStyle,
                        cursorColor:
                            _renderedTableStart == null &&
                                _renderedCalloutStart == null
                            ? null
                            : Colors.transparent,
                        // The caret height follows the rendered row (body, heading,
                        // or image row) instead of a fixed preferred line height.
                        cursorHeight: _caretHeight,
                        cursorOpacityAnimates: true,
                        selectionHeightStyle: BoxHeightStyle.tight,
                        // The projection carries its own per-line metrics, so the
                        // editable's forced body-style strut must stay disabled.
                        strutStyle: StrutStyle.disabled,
                        smartDashesType: SmartDashesType.disabled,
                        smartQuotesType: SmartQuotesType.disabled,
                        autocorrect: widget.autocorrect,
                        enableSuggestions: widget.enableSuggestions,
                        enableIMEPersonalizedLearning:
                            widget.enableIMEPersonalizedLearning,
                        decoration:
                            widget.editorDecoration ??
                            const InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            );
            return Listener(
              onPointerDown: _handleDocumentPointerDown,
              onPointerMove: _handleDocumentPointerMove,
              onPointerUp: _handleDocumentPointerUp,
              onPointerCancel: _handleDocumentPointerCancel,
              child: TextSelectionEdgeAutoScroll(
                controller: _textController,
                scrollController: _effectiveScrollController,
                child: editor,
              ),
            );
          },
        ),
      ),
    );
  }
}
