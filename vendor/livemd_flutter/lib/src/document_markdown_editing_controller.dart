import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'markdown_input_privacy.dart';
import 'desktop_text_context_menu.dart';
import 'live_markdown_annotation.dart';
import 'live_markdown_appearance.dart';
import 'live_markdown_media.dart';
import 'markdown_block.dart';
import 'markdown_block_parser.dart';
import 'markdown_editing_commands.dart';
import 'markdown_syntax_tree.dart';
import 'markdown_table.dart';
import 'markdown_paste_controller.dart';
import 'markdown_paste_region.dart';
import 'markdown_menu_presentation.dart';

typedef MarkdownInlineInteraction = void Function(MarkdownInlineNode node);
typedef MarkdownTaskInteraction = void Function(MarkdownLineNode line);
typedef MarkdownBlockInteraction = void Function(MarkdownBlock block);

enum CalloutEditingField { title, body }

typedef _CalloutInteractions = ({
  void Function(MarkdownBlock block) beginPointer,
  void Function(MarkdownBlock block) endPointer,
  void Function(MarkdownBlock block, CalloutEditingField field, int localOffset)
  startEditing,
  void Function(
    MarkdownBlock block,
    CalloutEditingField field,
    TextEditingValue value,
    Object editOrigin,
  )
  edit,
  void Function(MarkdownBlock block, int documentOffset) revealSource,
});

typedef _TableInteractions = ({
  void Function(MarkdownBlock block) beginPointer,
  void Function(MarkdownBlock block) endPointer,
  void Function(
    MarkdownBlock block,
    int rowIndex,
    int column,
    TextPosition position,
  )
  startEditing,
  bool Function(
    MarkdownBlock block,
    int rowIndex,
    int column,
    TextEditingValue value,
    Object editOrigin,
    bool textChanged,
  )
  editCell,
  bool Function(MarkdownBlock block, TextEditingValue value, Object editOrigin)
  editSource,
  ({int rowIndex, int column})? Function(
    MarkdownBlock block,
    int rowIndex,
    int column,
    MarkdownEditingCommand command,
  )
  runCommand,
  ({int rowIndex, int column})? Function(
    MarkdownBlock block,
    int rowIndex,
    int column,
  )
  materializeCell,
  void Function({required bool redo}) history,
  void Function(int documentOffset) exit,
});

/// Resolves a Markdown image destination to an [ImageProvider].
///
/// Receives the Markdown destination string. Implement this to map vault or
/// file references to your own providers. The default resolver maps `asset:`
/// to bundled [AssetImage]s and other destinations to [NetworkImage].
typedef LiveMarkdownImageResolver = ImageProvider Function(String destination);

/// Default [LiveMarkdownImageResolver]: `asset:` for the application bundle,
/// [NetworkImage] for everything else.
ImageProvider defaultLiveMarkdownImageResolver(String destination) {
  const prefix = 'asset:';
  if (destination.startsWith(prefix)) {
    return AssetImage(destination.substring(prefix.length));
  }
  return NetworkImage(destination);
}

/// The maximum width and reserved height of a standalone media slot, and the
/// extra height reserved around it.
///
/// The text engine anchors an inline placeholder about one body line below the
/// line top instead of growing the line around it, so the reserved line height
/// must cover the slot plus that inset on both sides. The visible picture is
/// centered in the reserved row and never overlaps its neighbors.
const double _imageSlotMaxWidth = 480.0;
const double _imageSlotHeight = 240.0;
const double _imageSlotInset = 32.0;
const double _audioSlotMaxWidth = 480.0;
const double _audioSlotHeight = 48.0;
const double _audioSlotInset = 8.0;
const double _calloutVerticalPadding = 10.0;
const double _calloutBodyGap = 6.0;
const double _tableCellExtraPadding = 2.0;
const double _tableControlGutter = 24.0;

/// Silique: extra left padding between a code-block panel edge and its glyphs.
const double _codeBlockIndent = 14.0;

double _naturalGlyphHeight(TextStyle style, TextScaler textScaler) {
  final fontSize = style.fontSize ?? 14;
  final painter = TextPainter(
    text: TextSpan(
      text: 'Ay',
      style: TextStyle(
        inherit: false,
        color: style.color,
        fontSize: fontSize,
        fontWeight: style.fontWeight,
        fontStyle: style.fontStyle,
        letterSpacing: style.letterSpacing,
        wordSpacing: style.wordSpacing,
        textBaseline: style.textBaseline,
        fontFamily: style.fontFamily,
        fontFamilyFallback: style.fontFamilyFallback,
        locale: style.locale,
        fontFeatures: style.fontFeatures,
        fontVariations: style.fontVariations,
      ),
    ),
    textDirection: TextDirection.ltr,
    textScaler: textScaler,
    maxLines: 1,
  )..layout();
  final height = painter.preferredLineHeight;
  painter.dispose();
  return height.isFinite && height > 0
      ? height
      : textScaler.scale(fontSize) * 1.17;
}

/// Whether [destination] points at a video file.
///
/// Markdown has no native video syntax, but editors (like Obsidian) render a
/// video element when an image embed's destination is a video file. The
/// library keeps the same `![alt](destination)` node and switches the slot at
/// render time based on the file extension.
bool isMarkdownVideoDestination(String destination) =>
    defaultLiveMarkdownMediaType(destination) == LiveMarkdownMediaType.video;

/// Builds the widget shown for a video embed. The default is a non-playing
/// placeholder; applications inject a real player here.
///
/// Receives the rendering context, Markdown destination, and alt text. Return
/// a widget that fits its parent constraints (inline slots can be very small).
/// Create and dispose player resources in that widget's State, not in this
/// callback. Resolve `asset:` paths in the application before loading playback.
typedef LiveMarkdownVideoBuilder = Widget Function(
  BuildContext context,
  String destination,
  String alt,
);

/// Whether [destination] points at an audio file, following the same
/// image-embed convention as video.
bool isMarkdownAudioDestination(String destination) =>
    defaultLiveMarkdownMediaType(destination) == LiveMarkdownMediaType.audio;

/// Builds the widget shown for an audio embed. The default is a non-playing
/// placeholder; applications inject a real player here.
///
/// Arguments and player ownership follow [LiveMarkdownVideoBuilder]. The
/// standalone audio slot is compact; inline embeds use surrounding line height.
typedef LiveMarkdownAudioBuilder = Widget Function(
  BuildContext context,
  String destination,
  String alt,
);

/// Projects one lossless Markdown source into a continuously editable span
/// tree. Every projected replacement occupies the same number of UTF-16 source
/// positions as the text it represents, so Flutter's native selection and IME
/// state remain document-global.
class DocumentMarkdownEditingController extends TextEditingController {
  DocumentMarkdownEditingController({
    required TextEditingValue value,
    this.parser = const MarkdownSyntaxParser(),
    this.blockParser = const MarkdownBlockParser(),
  }) : _projectionSelection = value.selection.isCollapsed
           ? value.selection
           : const TextSelection.collapsed(offset: -1),
       super.fromValue(value);

  // Range selection highlights the existing layout. Revealing every crossed
  // marker changes wrapping and feeds moving geometry back into native handles.
  // Keep the last caret's projection until an actual edit or a new caret.
  TextSelection _projectionSelection;
  bool holdLinkProjection = false;
  int textRevision = 0;

  /// Source-mode links are not navigation targets. Hit-test rendered labels
  /// through the editable paragraph instead of indivisible widget placeholders.
  Iterable<MarkdownInlineNode> get renderedLinks sync* {
    Iterable<MarkdownInlineNode> visit(List<MarkdownInlineNode> nodes) sync* {
      for (final node in nodes) {
        final caret = _projectionSelection.extentOffset;
        final active =
            _projectionSelection.isValid &&
            caret > node.fullRange.start &&
            caret < node.fullRange.end;
        if ((node.kind == MarkdownInlineKind.link ||
                node.kind == MarkdownInlineKind.wikiLink) &&
            !active) {
          yield node;
        } else {
          yield* visit(node.inlines);
        }
      }
    }

    for (final line in syntaxTree.lines) {
      yield* visit(line.inlines);
    }
  }

  @override
  set value(TextEditingValue next) {
    final previous = value;
    if (next.text != previous.text) textRevision++;
    if (next.text != previous.text ||
        (!holdLinkProjection &&
            (next.selection.isCollapsed || !next.selection.isValid))) {
      _projectionSelection = next.selection;
    } else if (!holdLinkProjection &&
        (previous.selection.isCollapsed || !previous.selection.isValid)) {
      _projectionSelection = previous.selection;
    }
    super.value = next;
  }

  final MarkdownSyntaxParser parser;
  final MarkdownBlockParser blockParser;

  @override
  void dispose() {
    // TextEditingController.dispose does not release its retained value.
    clear();
    _tree = null;
    _annotations = const [];
    super.dispose();
  }

  MarkdownSyntaxTree? _tree;
  TextStyle _baseStyle = const TextStyle(fontSize: 16, height: 1.5);
  List<TextStyle> _headingStyles = const [];
  late ResolvedLiveMarkdownAppearance _appearance;
  Color _linkColor = Colors.blue;
  Color _codeBackgroundColor = Colors.transparent;
  MarkdownStyleSheet? _markdownStyleSheet;
  double _contentWidth = 600;
  MarkdownInlineInteraction? _onInlineInteraction;
  MarkdownTaskInteraction? _onTaskInteraction;
  MarkdownTaskInteraction? _onTaskPointerDown;
  VoidCallback? _onTaskPointerUp;
  MarkdownBlockInteraction? _onBlockInteraction;
  _CalloutInteractions? _calloutInteractions;
  _TableInteractions? _tableInteractions;
  int? _renderedCalloutStart;
  int? _renderedTableStart;
  int? _sourceEditingTableStart;
  TextRange? _projectionComposing;
  LiveMarkdownImageResolver _imageResolver = defaultLiveMarkdownImageResolver;
  LiveMarkdownMediaTypeResolver? _mediaTypeResolver;
  TextScaler _textScaler = TextScaler.noScaling;
  LiveMarkdownVideoBuilder? _videoBuilder;
  LiveMarkdownAudioBuilder? _audioBuilder;
  List<LiveMarkdownAnnotation> _annotations = const [];

  MarkdownSyntaxTree get syntaxTree {
    final cached = _tree;
    if (cached != null && cached.source == text) return cached;
    return _tree = parser.parse(text);
  }

  void updateProjectionComposing(TextRange composing) {
    _projectionComposing = composing;
  }

  void updatePresentation({
    required TextStyle baseStyle,
    required List<TextStyle> headingStyles,
    required ResolvedLiveMarkdownAppearance appearance,
    required Color linkColor,
    required Color codeBackgroundColor,
    required MarkdownStyleSheet markdownStyleSheet,
    required double contentWidth,
    MarkdownInlineInteraction? onInlineInteraction,
    MarkdownTaskInteraction? onTaskInteraction,
    MarkdownTaskInteraction? onTaskPointerDown,
    VoidCallback? onTaskPointerUp,
    MarkdownBlockInteraction? onBlockInteraction,
    // ignore: library_private_types_in_public_api
    _CalloutInteractions? calloutInteractions,
    // This controller is package-internal; the public method only bridges
    // separate src libraries.
    // ignore: library_private_types_in_public_api
    _TableInteractions? tableInteractions,
    int? renderedCalloutStart,
    int? renderedTableStart,
    int? sourceEditingTableStart,
    TextRange? projectionComposing,
    LiveMarkdownImageResolver imageResolver = defaultLiveMarkdownImageResolver,
    LiveMarkdownMediaTypeResolver? mediaTypeResolver,
    TextScaler textScaler = TextScaler.noScaling,
    LiveMarkdownVideoBuilder? videoBuilder,
    LiveMarkdownAudioBuilder? audioBuilder,
    List<LiveMarkdownAnnotation> annotations = const [],
  }) {
    _baseStyle = baseStyle;
    _headingStyles = List.unmodifiable(headingStyles);
    _appearance = appearance;
    _linkColor = linkColor;
    _codeBackgroundColor = codeBackgroundColor;
    _markdownStyleSheet = markdownStyleSheet;
    _contentWidth = contentWidth;
    _onInlineInteraction = onInlineInteraction;
    _onTaskInteraction = onTaskInteraction;
    _onTaskPointerDown = onTaskPointerDown;
    _onTaskPointerUp = onTaskPointerUp;
    _onBlockInteraction = onBlockInteraction;
    _calloutInteractions = calloutInteractions;
    _tableInteractions = tableInteractions;
    _renderedCalloutStart = renderedCalloutStart;
    _renderedTableStart = renderedTableStart;
    _sourceEditingTableStart = sourceEditingTableStart;
    _projectionComposing = projectionComposing;
    _imageResolver = imageResolver;
    _mediaTypeResolver = mediaTypeResolver;
    _textScaler = textScaler;
    _videoBuilder = videoBuilder;
    _audioBuilder = audioBuilder;
    _annotations = annotations;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style == null ? _baseStyle : style.merge(_baseStyle);
    final builder = _DocumentProjectionBuilder(
      context: context,
      source: text,
      tree: syntaxTree,
      selection: selection,
      projectionSelection: _projectionSelection,
      composing: withComposing ? value.composing : TextRange.empty,
      tableComposing:
          _projectionComposing ??
          (withComposing ? value.composing : TextRange.empty),
      baseStyle: base,
      headingStyles: _headingStyles,
      appearance: _appearance,
      linkColor: _linkColor,
      codeBackgroundColor: _codeBackgroundColor,
      markdownStyleSheet: _markdownStyleSheet,
      contentWidth: _contentWidth,
      onInlineInteraction: _onInlineInteraction,
      onTaskInteraction: _onTaskInteraction,
      onTaskPointerDown: _onTaskPointerDown,
      onTaskPointerUp: _onTaskPointerUp,
      onBlockInteraction: _onBlockInteraction,
      calloutInteractions: _calloutInteractions,
      tableInteractions: _tableInteractions,
      renderedCalloutStart: _renderedCalloutStart,
      renderedTableStart: _renderedTableStart,
      sourceEditingTableStart: _sourceEditingTableStart,
      imageResolver: _imageResolver,
      mediaTypeResolver: _mediaTypeResolver,
      videoBuilder: _videoBuilder,
      audioBuilder: _audioBuilder,
      complexBlocks: _complexBlocks(),
      annotations: _annotations,
    );
    return TextSpan(style: base, children: builder.build());
  }

  List<MarkdownBlock> _complexBlocks() {
    return blockParser
        .parse(text)
        .where((block) {
          return block.type == MarkdownBlockType.codeFence ||
              block.type == MarkdownBlockType.callout ||
              block.type == MarkdownBlockType.table ||
              block.type == MarkdownBlockType.thematicBreak;
        })
        .toList(growable: false);
  }

  /// The natural glyph height at [offset] (ascent plus descent, without the
  /// extra leading of the line-height multiplier): the caret covers lowercase
  /// descenders and stays inside the visible text instead of the whole row.
  /// Media previews do not stretch the native caret; revealed source always
  /// uses the surrounding text style's natural glyph height.
  double caretHeightAt(int offset) {
    if (text.isEmpty) return _glyphHeightOf(_baseStyle);
    final clamped = offset < 0
        ? 0
        : offset > text.length
        ? text.length
        : offset;

    // A caret inside a complex block activates its source, which renders as
    // ordinary block-style lines.
    for (final block in _complexBlocks()) {
      if (clamped > block.sourceStart && clamped < block.sourceEnd) {
        return _glyphHeightOf(
          block.type == MarkdownBlockType.codeFence
              ? _codeHeightStyle()
              : _baseStyle,
        );
      }
    }

    for (final line in syntaxTree.lines) {
      final start = line.fullRange.start;
      final end = line.lineEndingRange.start;
      if (clamped < start || clamped > end) continue;
      return _glyphHeightOf(_heightStyleForLine(line));
    }
    return _glyphHeightOf(_baseStyle);
  }

  TextStyle _heightStyleForLine(MarkdownLineNode line) {
    var style = _baseStyle;
    if (line.kind == MarkdownLineKind.atxHeading) {
      final level = line.headingLevel ?? 1;
      if (level > 0 && level <= _headingStyles.length) {
        style = _baseStyle.merge(_headingStyles[level - 1]);
      }
    }
    return style;
  }

  TextStyle _codeHeightStyle() {
    final style = _baseStyle.merge(_markdownStyleSheet?.code);
    return style.copyWith(
      fontFamily: style.fontFamily ?? 'RobotoMono',
      fontFamilyFallback: style.fontFamilyFallback ?? const ['monospace'],
    );
  }

  double _glyphHeightOf(TextStyle style) =>
      _naturalGlyphHeight(style, _textScaler);
}

class _DocumentProjectionBuilder {
  _DocumentProjectionBuilder({
    required this.context,
    required this.source,
    required this.tree,
    required this.selection,
    required this.projectionSelection,
    required this.composing,
    required this.tableComposing,
    required this.baseStyle,
    required this.headingStyles,
    required this.appearance,
    required this.linkColor,
    required this.codeBackgroundColor,
    required this.markdownStyleSheet,
    required this.contentWidth,
    required this.onInlineInteraction,
    required this.onTaskInteraction,
    required this.onTaskPointerDown,
    required this.onTaskPointerUp,
    required this.onBlockInteraction,
    required this.calloutInteractions,
    required this.tableInteractions,
    required this.renderedCalloutStart,
    required this.renderedTableStart,
    required this.sourceEditingTableStart,
    required this.complexBlocks,
    this.annotations = const [],
    this.imageResolver = defaultLiveMarkdownImageResolver,
    this.mediaTypeResolver,
    this.videoBuilder,
    this.audioBuilder,
  });

  final BuildContext context;
  final String source;
  final MarkdownSyntaxTree tree;
  final TextSelection selection;
  // Only syntax reveal/layout uses the frozen caret. Embedded editors must
  // synchronize their editing state with the live document selection above.
  final TextSelection projectionSelection;
  final TextRange composing;
  final TextRange tableComposing;
  final TextStyle baseStyle;
  final List<TextStyle> headingStyles;
  final ResolvedLiveMarkdownAppearance appearance;
  Color get syntaxColor => appearance.syntaxColor;
  Color get quoteColor => appearance.quoteColor;
  Color get taskColor => appearance.taskColor;
  final Color linkColor;
  final Color codeBackgroundColor;
  final MarkdownStyleSheet? markdownStyleSheet;
  final double contentWidth;
  final MarkdownInlineInteraction? onInlineInteraction;
  final MarkdownTaskInteraction? onTaskInteraction;
  final MarkdownTaskInteraction? onTaskPointerDown;
  final VoidCallback? onTaskPointerUp;
  final MarkdownBlockInteraction? onBlockInteraction;
  final _CalloutInteractions? calloutInteractions;
  final _TableInteractions? tableInteractions;
  final int? renderedCalloutStart;
  final int? renderedTableStart;
  final int? sourceEditingTableStart;
  final List<MarkdownBlock> complexBlocks;
  final List<LiveMarkdownAnnotation> annotations;
  final LiveMarkdownImageResolver imageResolver;
  final LiveMarkdownMediaTypeResolver? mediaTypeResolver;
  final LiveMarkdownVideoBuilder? videoBuilder;
  final LiveMarkdownAudioBuilder? audioBuilder;

  final List<InlineSpan> _result = [];
  late final _InlineProjectionCore _inlineProjection = _InlineProjectionCore(
    context: context,
    source: source,
    sourceOffset: 0,
    rangeIsActive: _rangeIsActive,
    composing: composing,
    syntaxColor: syntaxColor,
    highlightColor: appearance.highlightColor,
    linkColor: linkColor,
    codeBackgroundColor: codeBackgroundColor,
    markdownStyleSheet: markdownStyleSheet,
    contentWidth: contentWidth,
    onInlineInteraction: onInlineInteraction,
    imageResolver: imageResolver,
    mediaTypeResolver: mediaTypeResolver,
    spans: _result,
    blockMediaRenderer: _appendBlockMedia,
    annotations: annotations,
  );

  List<InlineSpan> build() {
    var lineIndex = 0;
    var blockIndex = 0;
    while (lineIndex < tree.lines.length) {
      final line = tree.lines[lineIndex];
      while (blockIndex < complexBlocks.length &&
          complexBlocks[blockIndex].sourceStart < line.fullRange.start) {
        blockIndex++;
      }
      final block = blockIndex < complexBlocks.length
          ? complexBlocks[blockIndex]
          : null;
      if (block == null || block.sourceStart != line.fullRange.start) {
        _appendLine(line);
        lineIndex++;
        continue;
      }

      final active = _rangeIsActive(
        SourceRange(block.sourceStart, block.sourceEnd),
      );
      final keepRenderedTable =
          block.type == MarkdownBlockType.table &&
          renderedTableStart == block.sourceStart;
      final keepRenderedCallout =
          block.type == MarkdownBlockType.callout &&
          renderedCalloutStart == block.sourceStart;
      if (block.type == MarkdownBlockType.codeFence) {
        _appendCodeBlock(block, active: active);
      } else if (active && !keepRenderedTable && !keepRenderedCallout) {
        _appendActiveComplexBlock(block);
      } else {
        _appendComplexBlock(block);
      }

      MarkdownLineNode lastLine = line;
      while (lineIndex < tree.lines.length &&
          tree.lines[lineIndex].fullRange.start < block.sourceEnd) {
        lastLine = tree.lines[lineIndex];
        lineIndex++;
      }
      if (block.sourceEnd < lastLine.fullRange.end) {
        _appendText(block.sourceEnd, lastLine.fullRange.end, baseStyle);
      }
      blockIndex++;
    }
    return _result;
  }

  void _appendCodeBlock(MarkdownBlock block, {required bool active}) {
    final style = _complexSourceStyle(block);
    final fenceStyle = active ? _syntaxStyle(style) : _invisibleStyle(style);
    final firstLineEnd = block.source.indexOf('\n');
    if (firstLineEnd < 0) {
      _appendIndentedCodeRange(block.sourceStart, block.sourceEnd, fenceStyle);
      return;
    }
    final openingEnd = block.sourceStart + firstLineEnd;
    _appendIndentedCodeRange(block.sourceStart, openingEnd, fenceStyle);
    _appendText(openingEnd, openingEnd + 1, style);

    final closingStart = _hasClosingCodeFence(block.source)
        ? block.sourceStart + block.source.lastIndexOf('\n') + 1
        : block.sourceEnd;
    _appendIndentedCodeRange(openingEnd + 1, closingStart, style);
    if (closingStart < block.sourceEnd) {
      _appendIndentedCodeRange(closingStart, block.sourceEnd, fenceStyle);
    }
  }

  /// Silique: appends every line of `source[start..end)` with its first
  /// UTF-16 character (or surrogate pair) projected into an indented
  /// placeholder, keeping the rendered character count equal to the source
  /// span so document-global selection stays lossless.
  void _appendIndentedCodeRange(int start, int end, TextStyle style) {
    var lineStart = start;
    while (lineStart < end) {
      int? lineBreak;
      for (var offset = lineStart; offset < end; offset++) {
        if (source.codeUnitAt(offset) != 0x0a) continue;
        lineBreak = offset;
        break;
      }
      final lineEnd = lineBreak ?? end;
      if (lineStart < lineEnd) {
        final leadLength = _codeLeadLength(lineStart, lineEnd);
        _inlineProjection.appendIndentedCodeLead(lineStart, leadLength, style);
        if (lineStart + leadLength < lineEnd) {
          _appendText(lineStart + leadLength, lineEnd, style);
        }
      }
      if (lineBreak != null) {
        _appendText(lineBreak, lineBreak + 1, style);
      }
      lineStart = lineBreak == null ? end : lineBreak + 1;
    }
  }

  int _codeLeadLength(int start, int end) {
    final unit = source.codeUnitAt(start);
    if (unit < 0xd800 || unit > 0xdbff || start + 1 >= end) {
      return 1;
    }
    final next = source.codeUnitAt(start + 1);
    return next >= 0xdc00 && next <= 0xdfff ? 2 : 1;
  }

  void _appendComplexBlock(MarkdownBlock block) {
    final sourceStyle = _complexSourceStyle(block);
    final sourceHeight = _measureTextHeight(
      block.source,
      sourceStyle,
      maxWidth: contentWidth,
    );
    final previewExtra = _complexPreviewExtra(block);
    final lineHeight = _measureTextHeight('Ay', baseStyle);
    final sourceLineCount = '\n'.allMatches(block.source).length + 1;
    final tableRowCount = sourceLineCount > 1 ? sourceLineCount - 1 : 1;
    final tableCellVerticalPadding =
        lineHeight / (tableRowCount * 2) + _tableCellExtraPadding;
    final table = block.type == MarkdownBlockType.table
        ? MarkdownTableSource.fromBlock(source, block)
        : null;
    final previewHeight = sourceHeight + previewExtra;
    final child = switch (block.type) {
      MarkdownBlockType.thematicBreak => SizedBox(
        key: ValueKey('thematic-break-${block.sourceStart}'),
        height: sourceHeight,
        child: Divider(
          height: sourceHeight,
          color: syntaxColor.withValues(alpha: 0.5),
        ),
      ),
      MarkdownBlockType.callout => ConstrainedBox(
        key: ValueKey('callout-${block.sourceStart}'),
        constraints: BoxConstraints(minHeight: previewHeight),
        child: _InteractiveCalloutPreview(
          block: block,
          selection: selection,
          composing: composing,
          editing: renderedCalloutStart == block.sourceStart,
          styleSheet: markdownStyleSheet,
          accent: appearance.calloutAccentColor,
          backgroundColor: appearance.calloutBackgroundColor,
          borderSide: appearance.calloutBorderSide,
          borderRadius: appearance.calloutBorderRadius,
          interactions: calloutInteractions,
          videoBuilder: videoBuilder,
          audioBuilder: audioBuilder,
          imageResolver: imageResolver,
          mediaTypeResolver: mediaTypeResolver,
          onInlineInteraction: onInlineInteraction,
          highlightColor: appearance.highlightColor,
        ),
      ),
      MarkdownBlockType.codeFence => throw StateError(
        'Code fences use the native source projection.',
      ),
      MarkdownBlockType.table => _InteractiveTablePreview(
        key: ValueKey('table-${block.sourceStart}'),
        block: block,
        document: source,
        table: table!,
        syntaxColor: appearance.tableSyntaxColor,
        highlightColor: appearance.highlightColor,
        activeCellColor: appearance.tableActiveCellColor,
        styleSheet: markdownStyleSheet,
        minHeight: previewHeight,
        cellVerticalPadding: tableCellVerticalPadding,
        selection: selection,
        composing: tableComposing,
        editing: renderedTableStart == block.sourceStart,
        sourceEditing: sourceEditingTableStart == block.sourceStart,
        onInlineInteraction: onInlineInteraction,
        interactions: tableInteractions,
        imageResolver: imageResolver,
        mediaTypeResolver: mediaTypeResolver,
      ),
      _ => const SizedBox.shrink(),
    };
    final interactiveChild =
        block.type == MarkdownBlockType.table ||
            block.type == MarkdownBlockType.callout
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => onBlockInteraction?.call(block),
            child: child,
          );
    _result.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.top,
        child: MouseRegion(
          cursor: SystemMouseCursors.text,
          child: SizedBox(width: contentWidth, child: interactiveChild),
        ),
      ),
    );
    _appendCollapsedComplexSource(
      block.sourceStart + 1,
      block.sourceEnd,
      sourceStyle,
    );
  }

  void _appendActiveComplexBlock(MarkdownBlock block) {
    final style = _complexSourceStyle(block);
    final localAnchorOffset = switch (block.type) {
      MarkdownBlockType.callout => block.source.lastIndexOf('>'),
      MarkdownBlockType.table => block.source.lastIndexOf('|'),
      _ => block.source.length - 1,
    };
    final anchorOffset = block.sourceStart + localAnchorOffset;
    _appendText(block.sourceStart, anchorOffset, style);

    final anchorCharacter = source.substring(anchorOffset, anchorOffset + 1);
    final painter = TextPainter(
      text: TextSpan(text: anchorCharacter, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    final height =
        painter.preferredLineHeight * 2 + _complexPreviewExtra(block);
    painter.dispose();
    _result.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: SizedBox(
          width: width,
          height: height,
          child: Align(
            alignment: Alignment.topLeft,
            child: Text(
              anchorCharacter,
              style: style,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
    _appendText(anchorOffset + 1, block.sourceEnd, style);
  }

  double _complexPreviewExtra(MarkdownBlock block) {
    if (block.type == MarkdownBlockType.callout) {
      return _calloutVerticalPadding * 2 + _calloutBodyGap;
    }
    if (block.type == MarkdownBlockType.table) {
      final sourceLineCount = '\n'.allMatches(block.source).length + 1;
      final tableRowCount = sourceLineCount > 1 ? sourceLineCount - 1 : 1;
      return tableRowCount * _tableCellExtraPadding * 2 + _tableControlGutter;
    }
    return 0;
  }

  bool _hasClosingCodeFence(String blockSource) {
    final opening = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(blockSource);
    if (opening == null || !blockSource.contains('\n')) return false;
    final openingMarker = opening.group(1)!;
    final lastLine = blockSource.substring(blockSource.lastIndexOf('\n') + 1);
    final closing = RegExp(r'^ {0,3}(`+|~+)[ \t]*$').firstMatch(lastLine);
    final marker = closing?.group(1);
    return marker != null &&
        marker[0] == openingMarker[0] &&
        marker.length >= openingMarker.length;
  }

  void _appendCollapsedComplexSource(int start, int end, TextStyle style) {
    var cursor = start;
    for (var offset = start; offset < end; offset++) {
      final codeUnit = source.codeUnitAt(offset);
      if (codeUnit != 0x0a && codeUnit != 0x0d) continue;
      _appendText(cursor, offset, _tightHiddenStyle(style));
      _result.add(
        const WidgetSpan(
          alignment: PlaceholderAlignment.bottom,
          child: SizedBox.shrink(),
        ),
      );
      cursor = offset + 1;
    }
    _appendText(cursor, end, _tightHiddenStyle(style));
  }

  TextStyle _complexSourceStyle(MarkdownBlock block) {
    return switch (block.type) {
      MarkdownBlockType.codeFence => _codeSourceStyle(),
      MarkdownBlockType.table => baseStyle.merge(markdownStyleSheet?.tableBody),
      MarkdownBlockType.callout => baseStyle.merge(markdownStyleSheet?.p),
      MarkdownBlockType.thematicBreak => _syntaxStyle(baseStyle),
      _ => baseStyle,
    };
  }

  TextStyle _codeSourceStyle() {
    final style = baseStyle.merge(markdownStyleSheet?.code);
    return style.copyWith(
      fontFamily: style.fontFamily ?? 'RobotoMono',
      fontFamilyFallback: style.fontFamilyFallback ?? const ['monospace'],
      backgroundColor: Colors.transparent,
    );
  }

  double _measureTextHeight(String text, TextStyle style, {double? maxWidth}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth ?? contentWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  void _appendLine(MarkdownLineNode line) {
    final lineStyle = _styleForLine(line);
    final logicalEnd = line.lineEndingRange.start;
    // Preview size depends on the available width, not the length of the
    // Markdown source (attachment IDs and camera filenames can be long).
    final blockMedia = _blockMediaNode(line);

    if (!line.prefixRange.isCollapsed) {
      _appendPrefix(line, lineStyle);
    }

    var cursor = line.contentRange.start;
    for (final node in line.inlines) {
      if (cursor < node.fullRange.start) {
        _appendText(cursor, node.fullRange.start, lineStyle);
      }
      _appendInline(
        node,
        lineStyle,
        forceReveal: false,
        blockMedia: blockMedia,
      );
      cursor = node.fullRange.end;
    }
    if (cursor < line.contentRange.end) {
      _appendText(cursor, line.contentRange.end, lineStyle);
    }

    if (line.contentRange.end < logicalEnd) {
      final revealSuffix =
          line.kind == MarkdownLineKind.atxHeading && _lineIsActive(line);
      _appendText(
        line.contentRange.end,
        logicalEnd,
        revealSuffix
            ? _syntaxStyle(lineStyle)
            : line.kind == MarkdownLineKind.atxHeading
            ? _tightHiddenStyle(lineStyle)
            : _hiddenStyle(lineStyle),
      );
    }
    _appendText(
      line.lineEndingRange.start,
      line.lineEndingRange.end,
      lineStyle,
    );
  }

  MarkdownInlineNode? _blockMediaNode(MarkdownLineNode line) {
    MarkdownInlineNode? media;
    var hasOtherContent = false;

    void visit(MarkdownInlineNode node) {
      if (node.kind == MarkdownInlineKind.image) {
        if (media == null) {
          media = node;
        } else {
          hasOtherContent = true;
        }
        return;
      }
      if (node.kind == MarkdownInlineKind.text) {
        if (source
            .substring(node.fullRange.start, node.fullRange.end)
            .trim()
            .isNotEmpty) {
          hasOtherContent = true;
        }
        return;
      }
      final isFormattingContainer =
          node.kind == MarkdownInlineKind.bold ||
          node.kind == MarkdownInlineKind.italic ||
          node.kind == MarkdownInlineKind.strikethrough ||
          node.kind == MarkdownInlineKind.highlight;
      if (!isFormattingContainer || node.inlines.isEmpty) {
        hasOtherContent = true;
        return;
      }
      for (final child in node.inlines) {
        visit(child);
      }
    }

    for (final node in line.inlines) {
      visit(node);
    }
    return hasOtherContent ? null : media;
  }

  TextStyle _styleForLine(MarkdownLineNode line) {
    var style = baseStyle;
    if (line.kind == MarkdownLineKind.atxHeading) {
      final level = line.headingLevel ?? 1;
      if (level > 0 && level <= headingStyles.length) {
        style = baseStyle.merge(headingStyles[level - 1]);
      }
    }
    if (line.kind == MarkdownLineKind.taskListItem &&
        line.taskChecked == true) {
      style = style.copyWith(
        color: (style.color ?? Colors.black).withValues(alpha: 0.62),
        decoration: TextDecoration.lineThrough,
      );
    }
    return style;
  }

  void _appendPrefix(MarkdownLineNode line, TextStyle lineStyle) {
    final prefix = line.prefixRange;
    // The trailing separator belongs to the rendered content boundary. A caret
    // after "- " or "- [ ] " must keep an empty item formatted as well.
    final reveal = _rangeIsActive(prefix, includeStart: true);
    if (line.kind == MarkdownLineKind.atxHeading) {
      if (!reveal && line.contentRange.isCollapsed) {
        _appendText(prefix.start, prefix.end - 1, _tightHiddenStyle(lineStyle));
        _appendText(prefix.end - 1, prefix.end, lineStyle);
      } else {
        _appendText(
          prefix.start,
          prefix.end,
          reveal ? _syntaxStyle(lineStyle) : _tightHiddenStyle(lineStyle),
        );
      }
      return;
    }

    if (reveal && line.kind == MarkdownLineKind.taskListItem) {
      _appendRevealedTaskPrefix(prefix, lineStyle);
      return;
    }

    if (reveal ||
        (line.kind != MarkdownLineKind.unorderedListItem &&
            line.kind != MarkdownLineKind.orderedListItem &&
            line.kind != MarkdownLineKind.taskListItem &&
            line.kind != MarkdownLineKind.blockquote)) {
      _appendText(prefix.start, prefix.end, _syntaxStyle(lineStyle));
      return;
    }

    final marker = line.marker;
    if (marker == null || marker.isEmpty) {
      _appendText(prefix.start, prefix.end, _hiddenStyle(lineStyle));
      return;
    }

    final prefixText = source.substring(prefix.start, prefix.end);
    final markerOffset = prefixText.indexOf(marker);
    if (markerOffset < 0) {
      _appendText(prefix.start, prefix.end, _hiddenStyle(lineStyle));
      return;
    }
    final markerStart = prefix.start + markerOffset;

    if (line.kind == MarkdownLineKind.taskListItem) {
      // The leading bullet is part of the widget so the entire `- [ ] `
      // marker zone is one opaque hit target: clicking anywhere on it
      // toggles the task instead of placing the caret inside the marker
      // (which would reveal the source).
      _result.add(
        _taskWidget(
          line,
          lineStyle,
          leadingText: source.substring(prefix.start, markerStart),
        ),
      );
      // Retain real glyph metrics for the final source character so Flutter
      // can measure an empty task's end-of-text caret. It can be `]` when no
      // trailing separator has been typed yet, so keep its ink invisible too.
      _appendText(
        prefix.start + 1,
        prefix.end - 1,
        _tightHiddenStyle(lineStyle),
      );
      _appendText(prefix.end - 1, prefix.end, _invisibleStyle(lineStyle));
      return;
    }

    _appendText(prefix.start, markerStart, lineStyle);
    switch (line.kind) {
      case MarkdownLineKind.unorderedListItem:
        _result.add(
          TextSpan(
            text: '•',
            style: lineStyle.copyWith(color: syntaxColor),
          ),
        );
        _appendText(markerStart + 1, prefix.end, lineStyle);
        break;
      case MarkdownLineKind.orderedListItem:
        _appendText(
          markerStart,
          markerStart + marker.length,
          lineStyle.copyWith(color: syntaxColor),
        );
        _appendText(markerStart + marker.length, prefix.end, lineStyle);
        break;
      case MarkdownLineKind.blockquote:
        _result.add(
          TextSpan(
            text: '▏',
            style: lineStyle.copyWith(color: quoteColor),
          ),
        );
        _appendText(markerStart + 1, prefix.end, lineStyle);
        break;
      default:
        _appendText(markerStart, prefix.end, lineStyle);
    }
  }

  void _appendRevealedTaskPrefix(SourceRange prefix, TextStyle style) {
    final firstCharacter = source.substring(prefix.start, prefix.start + 1);
    final syntaxStyle = _syntaxStyle(style);
    final painter = TextPainter(
      text: TextSpan(text: firstCharacter, style: syntaxStyle),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    _result.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: SizedBox(
          width: width,
          height: _taskHitHeight(style),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              firstCharacter,
              style: syntaxStyle,
              textScaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
    _appendText(prefix.start + 1, prefix.end, syntaxStyle);
  }

  WidgetSpan _taskWidget(
    MarkdownLineNode line,
    TextStyle style, {
    required String leadingText,
  }) {
    final checked = line.taskChecked ?? false;
    final fontSize = style.fontSize ?? 16;
    final scaledFontSize = MediaQuery.textScalerOf(context).scale(fontSize);
    final size = scaledFontSize;
    final hitHeight = scaledFontSize * (style.height ?? 1.2);
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Semantics(
        checked: checked,
        button: true,
        label: checked ? 'Completed task' : 'Incomplete task',
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Listener(
            onPointerDown: (_) => onTaskPointerDown?.call(line),
            onPointerUp: (_) => onTaskPointerUp?.call(),
            onPointerCancel: (_) => onTaskPointerUp?.call(),
            child: GestureDetector(
              key: ValueKey('task-${line.fullRange.start}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onTaskInteraction?.call(line),
              child: SizedBox(
                height: hitHeight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(leadingText, style: style),
                    SizedBox(
                      width: size * 1.32,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Padding(
                          padding: EdgeInsets.only(right: size * 0.32),
                          child: Icon(
                            checked
                                ? Icons.check_box_rounded
                                : Icons.check_box_outline_blank_rounded,
                            size: size,
                            color: checked ? taskColor : syntaxColor,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  double _taskHitHeight(TextStyle style) {
    final fontSize = style.fontSize ?? 16;
    final scaledFontSize = MediaQuery.textScalerOf(context).scale(fontSize);
    return scaledFontSize * (style.height ?? 1.2) + 2;
  }

  void _appendInline(
    MarkdownInlineNode node,
    TextStyle inheritedStyle, {
    required bool forceReveal,
    MarkdownInlineNode? blockMedia,
  }) {
    _inlineProjection.appendInline(
      node,
      inheritedStyle,
      forceReveal: forceReveal,
      blockMedia: blockMedia,
    );
  }

  void _appendBlockMedia(
    MarkdownInlineNode node,
    TextStyle inheritedStyle, {
    required bool active,
  }) {
    final destination = node.destinationRange == null
        ? ''
        : unescapeMarkdownMedia(
            source.substring(
              node.destinationRange!.start,
              node.destinationRange!.end,
            ),
          );
    final alt = unescapeMarkdownMedia(
      source.substring(node.contentRange.start, node.contentRange.end),
    );
    final isVideo =
        destination.isNotEmpty &&
        resolveLiveMarkdownMediaType(
              destination,
              resolver: mediaTypeResolver,
            ) ==
            LiveMarkdownMediaType.video;
    final isAudio =
        destination.isNotEmpty &&
        resolveLiveMarkdownMediaType(
              destination,
              resolver: mediaTypeResolver,
            ) ==
            LiveMarkdownMediaType.audio;
    final slotKind = isVideo
        ? 'video'
        : isAudio
        ? 'audio'
        : 'image';
    final slotHeight = isAudio ? _audioSlotHeight : _imageSlotHeight;
    final slotInset = isAudio ? _audioSlotInset : _imageSlotInset;
    final maxWidth = isAudio ? _audioSlotMaxWidth : _imageSlotMaxWidth;
    final slotWidth = contentWidth > maxWidth ? maxWidth : contentWidth;
    final markerStyle = _syntaxStyle(inheritedStyle);
    var firstCharacter = '';
    var anchorWidth = 0.0;
    var sourceLineHeight = 0.0;
    if (active) {
      firstCharacter = source.substring(
        node.fullRange.start,
        node.fullRange.start + 1,
      );
      final painter = TextPainter(
        text: TextSpan(text: firstCharacter, style: markerStyle),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      anchorWidth = painter.width;
      sourceLineHeight = painter.preferredLineHeight;
      painter.dispose();
    }
    final interactivePreview = ExcludeSemantics(
      excluding: active,
      child: IgnorePointer(
        ignoring: active,
        child: Semantics(
          image: !isVideo && !isAudio,
          label: alt,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onInlineInteraction?.call(node),
              child: SizedBox(
                width: slotWidth,
                height: slotHeight,
                child: destination.isEmpty
                    ? _imageFallback(alt, inheritedStyle)
                    : isVideo
                    ? videoBuilder?.call(context, destination, alt) ??
                          _mediaPlaceholder(
                            alt,
                            destination,
                            inheritedStyle,
                            Icons.play_circle_outline,
                          )
                    : isAudio
                    ? audioBuilder?.call(context, destination, alt) ??
                          _audioPlaceholder(alt, destination, inheritedStyle)
                    : Image(
                        image: imageResolver(destination),
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        errorBuilder: (context, error, stackTrace) =>
                            _imageFallback(alt, inheritedStyle),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    _result.add(
      WidgetSpan(
        alignment: active
            ? PlaceholderAlignment.baseline
            : PlaceholderAlignment.middle,
        baseline: active ? TextBaseline.alphabetic : null,
        child: SizedBox(
          key: ValueKey('$slotKind-${node.fullRange.start}'),
          width: active ? anchorWidth : slotWidth,
          height: active
              ? sourceLineHeight + slotHeight + slotInset
              : slotHeight,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Align(
                alignment: Alignment.topLeft,
                child: active
                    ? Text(
                        firstCharacter,
                        style: markerStyle,
                        textScaler: MediaQuery.textScalerOf(context),
                      )
                    : const SizedBox.shrink(),
              ),
              Positioned(
                left: 0,
                top: active ? sourceLineHeight + slotInset / 2 : 0,
                child: interactivePreview,
              ),
            ],
          ),
        ),
      ),
    );
    if (active) {
      _appendText(
        node.fullRange.start + 1,
        node.contentRange.start,
        markerStyle,
      );
      _appendText(
        node.contentRange.start,
        node.contentRange.end,
        inheritedStyle,
      );
      _appendText(node.contentRange.end, node.fullRange.end, markerStyle);
    } else {
      _appendText(
        node.fullRange.start + 1,
        node.fullRange.end,
        _hiddenStyle(inheritedStyle, lineHeight: slotHeight + slotInset),
      );
    }
  }

  Widget _audioPlaceholder(String alt, String destination, TextStyle style) {
    final label = _markdownBasename(destination);
    return Container(
      color: codeBackgroundColor.withValues(alpha: 0.5),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            Icons.play_arrow_rounded,
            size: 24,
            color: syntaxColor.withValues(alpha: 0.9),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.isNotEmpty ? label : alt,
              style: style.copyWith(color: syntaxColor),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _mediaPlaceholder(
    String alt,
    String destination,
    TextStyle inheritedStyle,
    IconData icon,
  ) {
    final label = _markdownBasename(destination);
    return Container(
      color: codeBackgroundColor.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: syntaxColor.withValues(alpha: 0.9)),
          if (label.isNotEmpty || alt.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                label.isNotEmpty ? label : alt,
                style: inheritedStyle.copyWith(color: syntaxColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _imageFallback(String alt, TextStyle inheritedStyle) {
    return Container(
      height: 90,
      width: double.infinity,
      color: codeBackgroundColor.withValues(alpha: 0.5),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            color: syntaxColor.withValues(alpha: 0.8),
            size: 28,
          ),
          if (alt.isNotEmpty) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                alt,
                style: inheritedStyle.copyWith(color: syntaxColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  TextStyle _syntaxStyle(TextStyle style) =>
      _inlineProjection.syntaxStyle(style);

  /// Makes a standalone source row invisible without changing any glyph,
  /// baseline, wrapping, caret, or scroll geometry.
  TextStyle _invisibleStyle(TextStyle style) => style.copyWith(
    color: Colors.transparent,
    backgroundColor: Colors.transparent,
    decoration: TextDecoration.none,
  );

  /// Hides a source range while it keeps real layout positions.
  ///
  /// The hidden run keeps a zero glyph width but reserves the line height of
  /// its surroundings: with the forced editable-text strut disabled, a line
  /// is as tall as its tallest run, so collapsing the run height would
  /// collapse the line. [lineHeight] overrides the reserved height for
  /// rendered placeholders (such as images).
  TextStyle _hiddenStyle(TextStyle style, {double? lineHeight}) {
    final reserved =
        lineHeight ?? (style.fontSize ?? 14) * (style.height ?? 1.17);
    return style.copyWith(
      color: Colors.transparent,
      fontSize: 0.01,
      height: reserved / 0.01,
      letterSpacing: -0.01,
      decoration: TextDecoration.none,
      backgroundColor: Colors.transparent,
    );
  }

  /// The tightest hidden style for inline markers.
  ///
  /// Markers always share a line with visible content (or a [WidgetSpan]
  /// row), so collapsing their run height keeps the line height owned by the
  /// visible runs. Revealing such a marker swaps its style without changing
  /// the line height, keeping the following content vertically stable.
  TextStyle _tightHiddenStyle(TextStyle style) =>
      _inlineProjection.tightHiddenStyle(style);

  void _appendText(int start, int end, TextStyle style) =>
      _inlineProjection.appendText(start, end, style);

  bool _lineIsActive(MarkdownLineNode line) {
    final logicalRange = SourceRange(
      line.fullRange.start,
      line.lineEndingRange.start,
    );
    if (projectionSelection.isValid &&
        projectionSelection.isCollapsed &&
        projectionSelection.extentOffset == logicalRange.end &&
        logicalRange.end > logicalRange.start) {
      return true;
    }
    return _rangeIsActive(logicalRange, includeStart: true);
  }

  bool _rangeIsActive(SourceRange range, {bool includeStart = false}) {
    if (!projectionSelection.isValid) return false;
    if (projectionSelection.isCollapsed) {
      final offset = projectionSelection.extentOffset;
      final caretInside = includeStart
          ? offset >= range.start && offset < range.end
          : offset > range.start && offset < range.end;
      if (caretInside) return true;
    } else if (projectionSelection.start < range.end &&
        projectionSelection.end > range.start) {
      return true;
    }
    return composing.isValid &&
        !composing.isCollapsed &&
        composing.start < range.end &&
        composing.end > range.start;
  }
}

class _InlineProjectionCore {
  _InlineProjectionCore({
    required this.context,
    required this.source,
    required this.sourceOffset,
    required this.rangeIsActive,
    required this.composing,
    required this.syntaxColor,
    required this.highlightColor,
    required this.linkColor,
    required this.codeBackgroundColor,
    required this.markdownStyleSheet,
    required this.contentWidth,
    required this.onInlineInteraction,
    required this.imageResolver,
    this.mediaTypeResolver,
    required this.spans,
    this.blockMediaRenderer,
    this.collapseSyntax = false,
    this.sourceOffsets,
    this.sourceOffsetShift = 0,
    this.annotations = const [],
  });

  final BuildContext context;
  final String source;
  final int sourceOffset;
  final bool Function(SourceRange range) rangeIsActive;
  final TextRange composing;
  final Color syntaxColor;
  final Color highlightColor;
  final Color linkColor;
  final Color codeBackgroundColor;
  final MarkdownStyleSheet? markdownStyleSheet;
  final double contentWidth;
  final MarkdownInlineInteraction? onInlineInteraction;
  final LiveMarkdownImageResolver imageResolver;
  final LiveMarkdownMediaTypeResolver? mediaTypeResolver;
  final List<InlineSpan> spans;
  final void Function(
    MarkdownInlineNode node,
    TextStyle inheritedStyle, {
    required bool active,
  })?
  blockMediaRenderer;
  final bool collapseSyntax;
  final List<int>? sourceOffsets;
  final int sourceOffsetShift;
  final List<LiveMarkdownAnnotation> annotations;
  List<LiveMarkdownAnnotation>? _sortedAnnotations;

  /// Annotations sorted by start offset, built once per projection.
  ///
  /// Every text fragment is painted separately, so scanning the whole list per
  /// fragment would be quadratic in the number of matches. A binary search finds
  /// the first annotation that can intersect a fragment instead.
  List<LiveMarkdownAnnotation> get _sorted =>
      _sortedAnnotations ??= (annotations.where((a) => a.isVisible).toList()
        ..sort((a, b) => a.start.compareTo(b.start)));

  int _firstAnnotationAtOrAfter(int offset) {
    final list = _sorted;
    var low = 0, high = list.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (list[mid].end <= offset) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }

  void appendNodes(
    List<MarkdownInlineNode> nodes,
    int start,
    int end,
    TextStyle inheritedStyle, {
    bool forceReveal = false,
    MarkdownInlineNode? blockMedia,
  }) {
    var cursor = start;
    for (final node in nodes) {
      if (node.fullRange.end <= start || node.fullRange.start >= end) continue;
      final nodeStart = node.fullRange.start.clamp(start, end);
      if (cursor < nodeStart) {
        _appendLiteral(cursor, nodeStart, inheritedStyle);
      }
      if (node.kind == MarkdownInlineKind.text) {
        // A literal can straddle the requested range (e.g. a table's parser
        // sentinel). Never paint or map text outside that range.
        _appendLiteral(
          nodeStart,
          node.fullRange.end.clamp(start, end),
          inheritedStyle,
        );
      } else {
        appendInline(
          node,
          inheritedStyle,
          forceReveal: forceReveal,
          blockMedia: blockMedia,
        );
      }
      cursor = node.fullRange.end.clamp(start, end);
    }
    if (cursor < end) _appendLiteral(cursor, end, inheritedStyle);
  }

  void appendInline(
    MarkdownInlineNode node,
    TextStyle inheritedStyle, {
    required bool forceReveal,
    MarkdownInlineNode? blockMedia,
  }) {
    if (identical(node, blockMedia) && blockMediaRenderer != null) {
      blockMediaRenderer!(
        node,
        inheritedStyle,
        active: forceReveal || rangeIsActive(node.fullRange),
      );
      return;
    }
    if (node.kind == MarkdownInlineKind.text) {
      _appendLiteral(node.fullRange.start, node.fullRange.end, inheritedStyle);
      return;
    }

    final reveal = forceReveal || rangeIsActive(node.fullRange);
    if (!reveal &&
        !collapseSyntax &&
        (node.kind == MarkdownInlineKind.link ||
            node.kind == MarkdownInlineKind.wikiLink)) {
      _appendInteractiveLink(node, inheritedStyle);
      return;
    }
    if (node.kind == MarkdownInlineKind.image) {
      if (reveal) {
        _appendInlineSource(node, inheritedStyle);
      } else {
        _appendRenderedMedia(node, inheritedStyle);
      }
      return;
    }

    final contentStyle = _contentStyle(
      node.kind,
      inheritedStyle,
      fontSize: node.fontSize,
    );
    final markerStyle = reveal
        ? syntaxStyle(inheritedStyle)
        : tightHiddenStyle(inheritedStyle);
    final link =
        node.kind == MarkdownInlineKind.link ||
        node.kind == MarkdownInlineKind.wikiLink;
    if (!collapseSyntax) {
      if (link) {
        _appendRangeWithDelimiters(
          node.fullRange.start,
          node.contentRange.start,
          node.delimiterRanges,
          contentStyle,
          markerStyle,
        );
      } else {
        appendText(node.fullRange.start, node.contentRange.start, markerStyle);
      }
    }

    if (node.inlines.isEmpty) {
      final append = node.kind == MarkdownInlineKind.codeSpan
          ? appendText
          : _appendLiteral;
      append(node.contentRange.start, node.contentRange.end, contentStyle);
    } else {
      appendNodes(
        node.inlines,
        node.contentRange.start,
        node.contentRange.end,
        contentStyle,
        forceReveal: reveal,
        blockMedia: blockMedia,
      );
    }

    if (!collapseSyntax) {
      if (link) {
        _appendRangeWithDelimiters(
          node.contentRange.end,
          node.fullRange.end,
          node.delimiterRanges,
          contentStyle,
          markerStyle,
        );
      } else {
        appendText(node.contentRange.end, node.fullRange.end, markerStyle);
      }
    }
  }

  void appendText(int start, int end, TextStyle style) {
    if (start >= end) return;
    if (annotations.isEmpty) {
      _appendTextPiece(start, end, style);
      return;
    }
    // Split the range at every annotation boundary so that a highlight or an
    // annotation font size can never leak outside its own source range.
    final relevant = <LiveMarkdownAnnotation>[
      for (
        var i = _firstAnnotationAtOrAfter(start);
        i < _sorted.length && _sorted[i].start < end;
        i++
      )
        _sorted[i],
    ];
    if (relevant.isEmpty) {
      _appendTextPiece(start, end, style);
      return;
    }
    final cuts = <int>{start, end};
    for (final annotation in relevant) {
      if (annotation.start > start) cuts.add(annotation.start);
      if (annotation.end < end) cuts.add(annotation.end);
    }
    final ordered = cuts.toList()..sort();
    for (var i = 0; i + 1 < ordered.length; i++) {
      final pieceStart = ordered[i];
      final pieceEnd = ordered[i + 1];
      if (pieceStart >= pieceEnd) continue;
      _appendTextPiece(
        pieceStart,
        pieceEnd,
        _applyAnnotations(style, pieceStart, pieceEnd, relevant),
      );
    }
  }

  TextStyle _applyAnnotations(
    TextStyle style,
    int start,
    int end,
    List<LiveMarkdownAnnotation> relevant,
  ) {
    var result = style;
    for (final annotation in relevant) {
      if (annotation.start >= end || annotation.end <= start) continue;
      if (annotation.backgroundColor != null) {
        result = result.copyWith(backgroundColor: annotation.backgroundColor);
      }
      if (annotation.fontSize != null) {
        result = result.copyWith(fontSize: annotation.fontSize);
      }
    }
    return result;
  }

  void _appendTextPiece(int start, int end, TextStyle style) {
    if (!composing.isValid ||
        composing.isCollapsed ||
        composing.end <= start ||
        composing.start >= end) {
      spans.add(TextSpan(text: source.substring(start, end), style: style));
      _mapRange(start, end);
      return;
    }

    final composingStart = composing.start.clamp(start, end);
    final composingEnd = composing.end.clamp(start, end);
    if (start < composingStart) {
      spans.add(
        TextSpan(text: source.substring(start, composingStart), style: style),
      );
    }
    if (composingStart < composingEnd) {
      spans.add(
        TextSpan(
          text: source.substring(composingStart, composingEnd),
          style: style.copyWith(decoration: TextDecoration.underline),
        ),
      );
    }
    if (composingEnd < end) {
      spans.add(
        TextSpan(text: source.substring(composingEnd, end), style: style),
      );
    }
    _mapRange(start, end);
  }

  void _mapRange(int start, int end) {
    final offsets = sourceOffsets;
    if (offsets == null) return;
    offsets[offsets.length - 1] = start + sourceOffsetShift;
    for (var offset = start; offset < end; offset++) {
      offsets.add(offset + 1 + sourceOffsetShift);
    }
  }

  void _mapReplacement(int start, int end) {
    final offsets = sourceOffsets;
    if (offsets == null) return;
    offsets[offsets.length - 1] = start + sourceOffsetShift;
    offsets.add(end + sourceOffsetShift);
  }

  TextStyle syntaxStyle(TextStyle style) => style.copyWith(color: syntaxColor);

  TextStyle tightHiddenStyle(TextStyle style) => style.copyWith(
    color: Colors.transparent,
    fontSize: 0.01,
    height: 0.01,
    letterSpacing: -0.01,
    decoration: TextDecoration.none,
    backgroundColor: Colors.transparent,
  );

  void _appendLiteral(int start, int end, TextStyle style) {
    if (!collapseSyntax) {
      appendText(start, end, style);
      return;
    }
    var segmentStart = start;
    var cursor = start;
    while (cursor + 1 < end) {
      if (source.codeUnitAt(cursor) != 0x5c ||
          !_isEscapableMarkdownPunctuation(source.codeUnitAt(cursor + 1))) {
        cursor++;
        continue;
      }
      appendText(segmentStart, cursor, style);
      appendText(cursor + 1, cursor + 2, style);
      cursor += 2;
      segmentStart = cursor;
    }
    appendText(segmentStart, end, style);
  }

  void _appendInlineSource(MarkdownInlineNode node, TextStyle inheritedStyle) {
    final markerStyle = syntaxStyle(inheritedStyle);
    appendText(node.fullRange.start, node.contentRange.start, markerStyle);
    appendText(node.contentRange.start, node.contentRange.end, inheritedStyle);
    appendText(node.contentRange.end, node.fullRange.end, markerStyle);
  }

  void _appendInteractiveLink(
    MarkdownInlineNode node,
    TextStyle inheritedStyle,
  ) {
    if (!usesDesktopTextContextMenu) {
      _appendMobileInteractiveLink(node, inheritedStyle);
      return;
    }
    final labelStyle = _contentStyle(node.kind, inheritedStyle);
    // Keep label glyphs in RenderEditable's own paragraph. A WidgetSpan is
    // indivisible: all source positions after its first character share one
    // caret, preventing partial selection and correct native range geometry.
    final hidden = tightHiddenStyle(inheritedStyle);
    appendText(node.fullRange.start, node.contentRange.start, hidden);
    if (node.inlines.isEmpty) {
      appendText(node.contentRange.start, node.contentRange.end, labelStyle);
    } else {
      appendNodes(
        node.inlines,
        node.contentRange.start,
        node.contentRange.end,
        labelStyle,
        forceReveal: false,
      );
    }
    appendText(node.contentRange.end, node.fullRange.end, hidden);
  }

  // Preserve the established touch projection; desktop labels use native glyphs
  // above so a mouse can select an arbitrary substring instead of a whole slot.
  void _appendMobileInteractiveLink(
    MarkdownInlineNode node,
    TextStyle inheritedStyle,
  ) {
    final labelStyle = _contentStyle(node.kind, inheritedStyle);
    final labelSpan = _previewContentSpan(node, labelStyle);
    final displayText = source.substring(
      node.contentRange.start,
      node.contentRange.end,
    );
    final painter = TextPainter(
      text: labelSpan,
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: contentWidth);
    final size = Size(painter.width, painter.height);
    painter.dispose();
    final globalNode = _globalNode(node);
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Semantics(
          link: true,
          label: displayText,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey('link-${globalNode.fullRange.start}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onInlineInteraction?.call(globalNode),
              child: SizedBox.fromSize(
                size: size,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text.rich(
                    labelSpan,
                    textScaler: MediaQuery.textScalerOf(context),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    appendText(
      node.fullRange.start + 1,
      node.fullRange.end,
      tightHiddenStyle(inheritedStyle),
    );
  }

  void _appendRenderedMedia(MarkdownInlineNode node, TextStyle inheritedStyle) {
    final destination = node.destinationRange == null
        ? ''
        : unescapeMarkdownMedia(
            source.substring(
              node.destinationRange!.start,
              node.destinationRange!.end,
            ),
          );
    final alt = unescapeMarkdownMedia(
      source.substring(node.contentRange.start, node.contentRange.end),
    );
    final isVideo =
        resolveLiveMarkdownMediaType(
          destination,
          resolver: mediaTypeResolver,
        ) ==
        LiveMarkdownMediaType.video;
    final isAudio =
        resolveLiveMarkdownMediaType(
          destination,
          resolver: mediaTypeResolver,
        ) ==
        LiveMarkdownMediaType.audio;
    final kind = isVideo
        ? 'video'
        : isAudio
        ? 'audio'
        : 'image';
    final icon = isVideo
        ? Icons.play_circle_outline
        : isAudio
        ? Icons.graphic_eq_rounded
        : Icons.image_outlined;
    final scaler = MediaQuery.textScalerOf(context);
    final painter = TextPainter(
      text: TextSpan(
        text: collapseSyntax
            ? 'Ay'
            : source.substring(node.fullRange.start, node.fullRange.end),
        style: inheritedStyle,
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout(maxWidth: collapseSyntax ? double.infinity : contentWidth);
    final height = painter.preferredLineHeight;
    final width = collapseSyntax
        ? scaler.scale(inheritedStyle.fontSize ?? 16).clamp(0.0, height)
        : painter.maxIntrinsicWidth.clamp(0.0, contentWidth);
    final label = alt.isNotEmpty ? alt : _markdownBasename(destination);
    if (!collapseSyntax &&
        (painter.didExceedMaxLines ||
            contentWidth < height ||
            width < height + (label.isEmpty ? 0 : 11))) {
      painter.dispose();
      _appendInlineSource(node, inheritedStyle);
      return;
    }
    painter.dispose();

    final foreground =
        inheritedStyle.color ?? Theme.of(context).colorScheme.onSurface;
    final background = collapseSyntax
        ? markdownStyleSheet?.code?.backgroundColor ?? codeBackgroundColor
        : codeBackgroundColor.withValues(alpha: 0.55);
    final iconSize = collapseSyntax
        ? width
        : scaler.scale(inheritedStyle.fontSize ?? 16);
    final thumbnail = SizedBox.square(
      dimension: collapseSyntax ? width : height,
      child: destination.isEmpty || isVideo || isAudio
          ? ColoredBox(
              color: background,
              child: Icon(icon, size: iconSize, color: foreground),
            )
          : ClipRRect(
              borderRadius: BorderRadius.circular(collapseSyntax ? 3 : 4),
              child: Image(
                image: imageResolver(destination),
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) => ColoredBox(
                  color: background,
                  child: Icon(icon, size: iconSize, color: foreground),
                ),
              ),
            ),
    );
    final media = collapseSyntax
        ? SizedBox.square(dimension: width, child: thumbnail)
        : DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(4),
            ),
            child: SizedBox(
              width: width,
              height: height,
              child: Row(
                children: [
                  thumbnail,
                  if (label.isNotEmpty) ...[
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        label,
                        style: inheritedStyle.copyWith(height: 1),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
          );
    final globalNode = _globalNode(node);
    final alignment = collapseSyntax
        ? PlaceholderAlignment.middle
        : PlaceholderAlignment.baseline;
    spans.add(
      WidgetSpan(
        alignment: alignment,
        baseline: collapseSyntax ? null : TextBaseline.alphabetic,
        child: Semantics(
          image: !isVideo && !isAudio,
          label: alt,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: ValueKey('$kind-${globalNode.fullRange.start}'),
              behavior: HitTestBehavior.opaque,
              onTap: () => onInlineInteraction?.call(globalNode),
              child: media,
            ),
          ),
        ),
      ),
    );
    _mapReplacement(node.fullRange.start, node.fullRange.end);
    if (!collapseSyntax) {
      appendText(
        node.fullRange.start + 1,
        node.fullRange.end,
        tightHiddenStyle(inheritedStyle),
      );
    }
  }

  TextSpan _previewContentSpan(
    MarkdownInlineNode node,
    TextStyle inheritedStyle,
  ) {
    if (node.inlines.isEmpty) {
      return TextSpan(
        text: source.substring(node.contentRange.start, node.contentRange.end),
        style: inheritedStyle,
      );
    }
    final children = <InlineSpan>[];
    var cursor = node.contentRange.start;
    for (final child in node.inlines) {
      if (cursor < child.fullRange.start) {
        children.add(
          TextSpan(
            text: source.substring(cursor, child.fullRange.start),
            style: inheritedStyle,
          ),
        );
      }
      children.add(_previewNodeSpan(child, inheritedStyle));
      cursor = child.fullRange.end;
    }
    if (cursor < node.contentRange.end) {
      children.add(
        TextSpan(
          text: source.substring(cursor, node.contentRange.end),
          style: inheritedStyle,
        ),
      );
    }
    return TextSpan(style: inheritedStyle, children: children);
  }

  TextSpan _previewNodeSpan(MarkdownInlineNode node, TextStyle inheritedStyle) {
    if (node.kind == MarkdownInlineKind.text) {
      return TextSpan(
        text: source.substring(node.fullRange.start, node.fullRange.end),
        style: inheritedStyle,
      );
    }
    return _previewContentSpan(
      node,
      _contentStyle(node.kind, inheritedStyle, fontSize: node.fontSize),
    );
  }

  void _appendRangeWithDelimiters(
    int start,
    int end,
    List<SourceRange> delimiters,
    TextStyle contentStyle,
    TextStyle delimiterStyle,
  ) {
    if (start >= end) return;
    final relevant =
        delimiters
            .where((range) => range.end > start && range.start < end)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    var cursor = start;
    for (final delimiter in relevant) {
      final delimiterStart = delimiter.start.clamp(start, end);
      final delimiterEnd = delimiter.end.clamp(start, end);
      if (cursor < delimiterStart) {
        appendText(cursor, delimiterStart, contentStyle);
      }
      if (delimiterStart < delimiterEnd) {
        appendText(delimiterStart, delimiterEnd, delimiterStyle);
      }
      cursor = delimiterEnd;
    }
    if (cursor < end) appendText(cursor, end, contentStyle);
  }

  TextStyle _contentStyle(
    MarkdownInlineKind kind,
    TextStyle inherited, {
    double? fontSize,
  }) {
    return switch (kind) {
      MarkdownInlineKind.bold => inherited.copyWith(
        fontWeight: FontWeight.w700,
      ),
      MarkdownInlineKind.italic => inherited.copyWith(
        fontStyle: FontStyle.italic,
      ),
      MarkdownInlineKind.strikethrough => inherited.copyWith(
        decoration: TextDecoration.lineThrough,
      ),
      MarkdownInlineKind.highlight => inherited.copyWith(
        backgroundColor: highlightColor,
      ),
      MarkdownInlineKind.codeSpan => _codeSpanStyle(inherited),
      MarkdownInlineKind.link || MarkdownInlineKind.wikiLink =>
        inherited
            .merge(markdownStyleSheet?.a)
            .copyWith(
              color: linkColor,
              decoration:
                  markdownStyleSheet?.a?.decoration ?? TextDecoration.underline,
              decorationColor:
                  markdownStyleSheet?.a?.decorationColor ?? linkColor,
            ),
      MarkdownInlineKind.image || MarkdownInlineKind.text => inherited,
      MarkdownInlineKind.fontSize => inherited.copyWith(
        fontSize: fontSize ?? inherited.fontSize,
      ),
    };
  }

  TextStyle _codeSpanStyle(TextStyle inherited) {
    final merged = inherited.merge(markdownStyleSheet?.code);
    return merged.copyWith(
      fontFamily: markdownStyleSheet?.code?.fontFamily ?? 'RobotoMono',
      fontFamilyFallback: merged.fontFamilyFallback ?? const ['monospace'],
      backgroundColor: codeBackgroundColor,
    );
  }

  /// Silique: renders the [length] UTF-16 units at [start] inside a
  /// baseline-aligned placeholder preceded by [_codeBlockIndent] logical
  /// pixels of left padding. The placeholder occupies exactly the same source
  /// positions as the character it paints, so selection, caret, and hit-test
  /// offsets stay document-global without mutating the stored Markdown.
  void appendIndentedCodeLead(int start, int length, TextStyle style) {
    final end = start + length;
    var leadStyle = style;
    if (composing.isValid &&
        !composing.isCollapsed &&
        composing.start < end &&
        composing.end > start) {
      leadStyle = leadStyle.copyWith(decoration: TextDecoration.underline);
    }
    final relevant = <LiveMarkdownAnnotation>[
      for (
        var i = _firstAnnotationAtOrAfter(start);
        i < _sorted.length && _sorted[i].start < end;
        i++
      )
        _sorted[i],
    ];
    if (relevant.isNotEmpty) {
      leadStyle = _applyAnnotations(leadStyle, start, end, relevant);
    }
    spans.add(
      WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: Padding(
          padding: const EdgeInsets.only(left: _codeBlockIndent),
          child: Text(
            source.substring(start, end),
            key: ValueKey('code-indent-$start'),
            style: leadStyle,
            maxLines: 1,
            textScaler: MediaQuery.textScalerOf(context),
          ),
        ),
      ),
    );
  }

  MarkdownInlineNode _globalNode(MarkdownInlineNode node) {
    if (sourceOffset == 0) return node;
    SourceRange shift(SourceRange range) =>
        SourceRange(range.start + sourceOffset, range.end + sourceOffset);

    return MarkdownInlineNode(
      kind: node.kind,
      fullRange: shift(node.fullRange),
      contentRange: shift(node.contentRange),
      delimiterRanges: node.delimiterRanges.map(shift).toList(growable: false),
      destinationRange: node.destinationRange == null
          ? null
          : shift(node.destinationRange!),
      titleRange: node.titleRange == null ? null : shift(node.titleRange!),
      targetRange: node.targetRange == null ? null : shift(node.targetRange!),
      aliasRange: node.aliasRange == null ? null : shift(node.aliasRange!),
    );
  }
}

class _TableCellProjection {
  const _TableCellProjection({required this.span, required this.sourceOffsets});

  factory _TableCellProjection.build(
    BuildContext context, {
    required String source,
    required int sourceOffset,
    required TextStyle style,
    required MarkdownStyleSheet sheet,
    required Color syntaxColor,
    required Color highlightColor,
    required MarkdownInlineInteraction? onInlineInteraction,
    required LiveMarkdownImageResolver imageResolver,
    LiveMarkdownMediaTypeResolver? mediaTypeResolver,
  }) {
    final paddedSource = '\u200B$source';
    final spans = <InlineSpan>[];
    final sourceOffsets = <int>[0];
    final theme = Theme.of(context);
    final projection = _InlineProjectionCore(
      context: context,
      source: paddedSource,
      sourceOffset: sourceOffset - 1,
      rangeIsActive: (_) => false,
      composing: TextRange.empty,
      syntaxColor: syntaxColor,
      highlightColor: highlightColor,
      linkColor: sheet.a?.color ?? theme.colorScheme.primary,
      codeBackgroundColor:
          sheet.code?.backgroundColor ?? theme.colorScheme.surfaceContainerHigh,
      markdownStyleSheet: sheet,
      contentWidth: double.infinity,
      onInlineInteraction: onInlineInteraction,
      imageResolver: imageResolver,
      mediaTypeResolver: mediaTypeResolver,
      spans: spans,
      collapseSyntax: true,
      sourceOffsets: sourceOffsets,
      sourceOffsetShift: -1,
    );
    final line = const MarkdownSyntaxParser().parse(paddedSource).lines.first;
    projection.appendNodes(line.inlines, 1, paddedSource.length, style);
    if (spans.isEmpty) {
      spans.add(TextSpan(text: '\u200B', style: style));
      sourceOffsets.add(0);
    }
    return _TableCellProjection(
      span: TextSpan(style: style, children: List.unmodifiable(spans)),
      sourceOffsets: List.unmodifiable(sourceOffsets),
    );
  }

  final TextSpan span;
  final List<int> sourceOffsets;

  int sourceOffsetAt(int displayOffset) =>
      sourceOffsets[displayOffset.clamp(0, sourceOffsets.length - 1)];
}

bool _isEscapableMarkdownPunctuation(int codeUnit) =>
    codeUnit >= 0x21 && codeUnit <= 0x2f ||
    codeUnit >= 0x3a && codeUnit <= 0x40 ||
    codeUnit >= 0x5b && codeUnit <= 0x60 ||
    codeUnit >= 0x7b && codeUnit <= 0x7e;

String _markdownBasename(String path) {
  final slash = path.lastIndexOf('/');
  var end = path.length;
  final query = path.indexOf('?');
  if (query >= 0 && query < end) end = query;
  final hash = path.indexOf('#');
  if (hash >= 0 && hash < end) end = hash;
  return path.substring(slash + 1, end);
}

class _InteractiveTablePreview extends StatefulWidget {
  const _InteractiveTablePreview({
    required this.block,
    required this.document,
    required this.table,
    required this.syntaxColor,
    required this.highlightColor,
    required this.activeCellColor,
    required this.styleSheet,
    required this.minHeight,
    required this.cellVerticalPadding,
    required this.selection,
    required this.composing,
    required this.editing,
    required this.sourceEditing,
    required this.onInlineInteraction,
    required this.interactions,
    required this.imageResolver,
    this.mediaTypeResolver,
    super.key,
  });

  final MarkdownBlock block;
  final String document;
  final MarkdownTableSource table;
  final Color syntaxColor;
  final Color highlightColor;
  final Color activeCellColor;
  final MarkdownStyleSheet? styleSheet;
  final double minHeight;
  final double cellVerticalPadding;
  final TextSelection selection;
  final TextRange composing;
  final bool editing;
  final bool sourceEditing;
  final MarkdownInlineInteraction? onInlineInteraction;
  final _TableInteractions? interactions;
  final LiveMarkdownImageResolver imageResolver;
  final LiveMarkdownMediaTypeResolver? mediaTypeResolver;

  @override
  State<_InteractiveTablePreview> createState() =>
      _InteractiveTablePreviewState();
}

class _InteractiveTablePreviewState extends State<_InteractiveTablePreview> {
  bool _hovered = false;
  bool _syncingCell = false;
  bool _syncingSource = false;
  ({int rowIndex, int column})? _active;
  late final TextEditingController _cellController;
  late final TextEditingController _sourceController;
  late final FocusNode _cellFocus;
  late final FocusNode _sourceFocus;
  late final ScrollController _horizontalScroll;
  final GlobalKey _sourceEditorHostKey = GlobalKey();
  final GlobalKey<MarkdownPasteRegionState> _cellPasteKey = GlobalKey();
  VerticalCaretMovementRun? _verticalCaretRun;
  RenderEditable? _verticalCaretEditable;
  String _lastCellText = '';
  Object _editOrigin = Object();
  Object _sourceEditOrigin = Object();

  @override
  void initState() {
    super.initState();
    _cellController = TextEditingController()..addListener(_handleCellValue);
    _sourceController = TextEditingController()
      ..addListener(_handleSourceValue);
    _cellFocus = FocusNode(onKeyEvent: _handleCellKeyEvent);
    _sourceFocus = FocusNode(onKeyEvent: _handleSourceKeyEvent);
    _horizontalScroll = ScrollController();
  }

  @override
  void didUpdateWidget(covariant _InteractiveTablePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    final hadEditingFocus =
        _sourceFocus.hasFocus ||
        _cellFocus.hasFocus ||
        (Focus.maybeOf(context)?.hasFocus ?? false);
    if (widget.sourceEditing) {
      if (!oldWidget.sourceEditing) {
        _sourceEditOrigin = Object();
        _verticalCaretRun = null;
        _verticalCaretEditable = null;
      }
      _active = null;
      _cellFocus.unfocus();
      _syncSourceValue();
      if (!oldWidget.sourceEditing || hadEditingFocus) _requestSourceFocus();
      return;
    }
    if (oldWidget.sourceEditing) _sourceFocus.unfocus();
    if (!widget.editing) {
      if (_active == null) return;
      _active = null;
      _cellFocus.unfocus();
      return;
    }
    final selected = _selectedEditableLocation();
    if (selected == null) {
      _active = null;
      _cellFocus.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.interactions?.exit(widget.selection.extentOffset);
      });
      return;
    }
    final changedCell =
        _active?.rowIndex != selected.rowIndex ||
        _active?.column != selected.column;
    if (changedCell) {
      _editOrigin = Object();
      _active = (rowIndex: selected.rowIndex, column: selected.column);
    }
    _syncActiveCell();
    if ((changedCell || !_cellFocus.hasFocus) &&
        (!oldWidget.editing || hadEditingFocus)) {
      _requestCellFocus();
    }
  }

  void _syncSourceValue() {
    final text = widget.block.source;
    final selection = TextSelection(
      baseOffset: (widget.selection.baseOffset - widget.block.sourceStart)
          .clamp(0, text.length),
      extentOffset: (widget.selection.extentOffset - widget.block.sourceStart)
          .clamp(0, text.length),
      affinity: widget.selection.affinity,
      isDirectional: widget.selection.isDirectional,
    );
    final globalComposing = widget.composing;
    final composing =
        globalComposing.isValid &&
            globalComposing.isNormalized &&
            globalComposing.start >= widget.block.sourceStart &&
            globalComposing.end <= widget.block.sourceEnd
        ? TextRange(
            start: globalComposing.start - widget.block.sourceStart,
            end: globalComposing.end - widget.block.sourceStart,
          )
        : TextRange.empty;
    final next = TextEditingValue(
      text: text,
      selection: selection,
      composing: composing,
    );
    if (_sourceController.value == next) return;
    _syncingSource = true;
    _sourceController.value = next;
    _syncingSource = false;
  }

  MarkdownTableLocation? _selectedEditableLocation() {
    final selection = widget.selection;
    if (!selection.isValid) return null;
    final base = widget.table.locationAt(selection.baseOffset);
    final extent = widget.table.locationAt(selection.extentOffset);
    if (base == null ||
        extent == null ||
        base.rowIndex == 1 ||
        base.column >= widget.table.columnCount ||
        extent.column >= widget.table.columnCount ||
        base.rowIndex != extent.rowIndex ||
        base.column != extent.column) {
      return null;
    }
    final cell = extent.cell;
    bool offsetIsEditable(int offset) {
      if (cell.contentStart == cell.contentEnd) {
        return offset == cell.editingOffset;
      }
      return offset >= cell.contentStart && offset <= cell.contentEnd;
    }

    final ownsTransientPadding =
        _active?.rowIndex == extent.rowIndex &&
        _active?.column == extent.column &&
        _cellValueMatchesDocument(cell);
    if ((!offsetIsEditable(selection.baseOffset) ||
            !offsetIsEditable(selection.extentOffset)) &&
        !ownsTransientPadding) {
      return null;
    }
    final composing = widget.composing;
    if (composing.isValid &&
        !composing.isCollapsed &&
        (composing.start < cell.contentStart ||
            composing.end > cell.contentEnd) &&
        !ownsTransientPadding) {
      return null;
    }
    return extent;
  }

  @override
  void dispose() {
    _cellController.removeListener(_handleCellValue);
    _sourceController.removeListener(_handleSourceValue);
    _cellController.clear();
    _sourceController.clear();
    _cellController.dispose();
    _sourceController.dispose();
    _cellFocus.dispose();
    _sourceFocus.dispose();
    _horizontalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sheet =
        widget.styleSheet ?? MarkdownStyleSheet.fromTheme(Theme.of(context));
    final displayRows = <int>[
      0,
      for (var row = 2; row < widget.table.rows.length; row++) row,
    ];
    final showControls = !widget.sourceEditing && (_hovered || _active != null);
    final rowAnchor = widget.table.rows.length > 2
        ? widget.table.rows.length - 1
        : 0;
    final table = Table(
      defaultColumnWidth: sheet.tableColumnWidth ?? const FlexColumnWidth(),
      defaultVerticalAlignment: sheet.tableVerticalAlignment,
      border: sheet.tableBorder,
      children: [
        for (final rowIndex in displayRows)
          TableRow(
            children: [
              for (var column = 0; column < widget.table.columnCount; column++)
                _buildCell(sheet, rowIndex, column),
            ],
          ),
      ],
    );
    final borderRadius = sheet.tableBorder?.borderRadius;
    final clippedTable = borderRadius == null
        ? table
        : ClipRRect(borderRadius: borderRadius, child: table);
    final scrollableColumns =
        sheet.tableColumnWidth is FixedColumnWidth ||
        sheet.tableColumnWidth is IntrinsicColumnWidth;
    final tableBody = scrollableColumns
        ? LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              controller: _horizontalScroll,
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: clippedTable,
              ),
            ),
          )
        : clippedTable;
    final sourceStyle =
        sheet.tableBody ?? sheet.p ?? DefaultTextStyle.of(context).style;
    final sourceEditor = SizedBox(
      key: _sourceEditorHostKey,
      child: MarkdownPasteRegion(
        area: MarkdownPasteArea.tableSource,
        containerStart: widget.block.sourceStart,
        toDocumentOffset: (offset) => widget.block.sourceStart + offset,
        field: TextField(
          readOnly: MarkdownInputPrivacy.of(context)?.readOnly ?? false,
          key: ValueKey('table-source-${widget.block.sourceStart}'),
          contextMenuBuilder: markdownPasteContextMenu,
          controller: _sourceController,
          contentInsertionConfiguration: markdownContentInsertionConfiguration(
            context,
            _sourceController,
          ),
          focusNode: _sourceFocus,
          expands: true,
          minLines: null,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: sourceStyle,
          strutStyle: StrutStyle.disabled,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
          autocorrect: MarkdownInputPrivacy.of(context)?.autocorrect ?? true,
          enableSuggestions:
              MarkdownInputPrivacy.of(context)?.enableSuggestions ?? true,
          enableIMEPersonalizedLearning:
              MarkdownInputPrivacy.of(context)?.enableIMEPersonalizedLearning ??
              true,
          selectAllOnFocus: false,
          decoration: const InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );

    final body = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.minHeight),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Opacity(
              opacity: widget.sourceEditing ? 0 : 1,
              child: Padding(
                padding: const EdgeInsets.only(
                  right: _tableControlGutter,
                  bottom: _tableControlGutter,
                ),
                child: tableBody,
              ),
            ),
            if (widget.sourceEditing)
              Positioned.fill(
                child: ColoredBox(
                  color: Theme.of(context).colorScheme.surface,
                  child: sourceEditor,
                ),
              ),
            if (showControls && widget.interactions != null) ...[
              Positioned(
                left: 0,
                right: _tableControlGutter,
                bottom: 0,
                height: _tableControlGutter,
                child: Center(
                  child: _addButton(
                    key: ValueKey('table-add-row-${widget.block.sourceStart}'),
                    tooltip: 'Add table row',
                    onTap: () => _runCommand(
                      rowAnchor,
                      0,
                      MarkdownEditingCommand.tableInsertRowBelow,
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 0,
                bottom: _tableControlGutter,
                width: _tableControlGutter,
                child: Center(
                  child: _addButton(
                    key: ValueKey(
                      'table-add-column-${widget.block.sourceStart}',
                    ),
                    tooltip: 'Add table column',
                    onTap: () => _runCommand(
                      0,
                      widget.table.columnCount - 1,
                      MarkdownEditingCommand.tableInsertColumnRight,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    return _isolatedTableEditingRegion(body);
  }

  Widget _isolatedTableEditingRegion(Widget child) {
    return FocusScope(
      parentNode: FocusScope.of(context),
      child: Actions(
        actions: <Type, Action<Intent>>{
          DeleteCharacterIntent: _ForwardingTextAction<DeleteCharacterIntent>(),
          ExtendSelectionByCharacterIntent:
              _ForwardingTextAction<ExtendSelectionByCharacterIntent>(),
        },
        child: child,
      ),
    );
  }

  Widget _buildCell(MarkdownStyleSheet sheet, int rowIndex, int column) {
    final row = widget.table.rows[rowIndex];
    final cell = column < row.cells.length ? row.cells[column] : null;
    final active =
        widget.editing &&
        _active?.rowIndex == rowIndex &&
        _active?.column == column &&
        cell != null;
    final header = rowIndex == 0;
    final bodyStyle =
        sheet.tableBody ?? sheet.p ?? DefaultTextStyle.of(context).style;
    final style = header ? bodyStyle.merge(sheet.tableHead) : bodyStyle;
    final requestedPadding = header
        ? sheet.tableHeadCellsPadding ?? sheet.tableCellsPadding
        : sheet.tableCellsPadding;
    final horizontalPadding =
        requestedPadding ?? const EdgeInsets.symmetric(horizontal: 12);
    final padding = horizontalPadding.copyWith(
      top: widget.cellVerticalPadding,
      bottom: widget.cellVerticalPadding,
    );
    final decoration = header
        ? sheet.tableHeadCellsDecoration ?? sheet.tableCellsDecoration
        : sheet.tableCellsDecoration;
    final source = cell?.textOf(widget.document) ?? '';
    final projection = _TableCellProjection.build(
      context,
      source: source,
      sourceOffset: cell?.contentStart ?? widget.block.sourceStart,
      style: style,
      sheet: sheet,
      syntaxColor: widget.syntaxColor,
      highlightColor: widget.highlightColor,
      onInlineInteraction: widget.onInlineInteraction,
      imageResolver: widget.imageResolver,
      mediaTypeResolver: widget.mediaTypeResolver,
    );
    final textAlign = _textAlignForColumn(column, sheet);
    final renderedKey = GlobalObjectKey((this, rowIndex, column));
    final rendered = _renderedCell(projection, textAlign, key: renderedKey);
    final editor = MarkdownPasteRegion(
      key: active ? _cellPasteKey : null,
      area: MarkdownPasteArea.tableCell,
      containerStart: widget.block.sourceStart,
      row: rowIndex,
      column: column,
      toDocumentOffset: (offset) =>
          (cell == null
              ? widget.block.sourceStart
              : cell.contentStart == cell.contentEnd
              ? cell.editingOffset
              : cell.contentStart) +
          offset,
      field: TextField(
        readOnly: MarkdownInputPrivacy.of(context)?.readOnly ?? false,
        key: ValueKey(
          'table-editor-${widget.block.sourceStart}-$rowIndex-$column',
        ),
        controller: _cellController,
        contentInsertionConfiguration: markdownContentInsertionConfiguration(
          context,
          _cellController,
        ),
        focusNode: _cellFocus,
        minLines: 1,
        maxLines: 1,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.next,
        onEditingComplete: () {},
        onSubmitted: (_) =>
            _runCommand(rowIndex, column, MarkdownEditingCommand.enter),
        contextMenuBuilder: markdownCellPasteContextMenu,
        style: style,
        textAlign: textAlign,
        strutStyle: StrutStyle.disabled,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        autocorrect: MarkdownInputPrivacy.of(context)?.autocorrect ?? true,
        enableSuggestions:
            MarkdownInputPrivacy.of(context)?.enableSuggestions ?? true,
        enableIMEPersonalizedLearning:
            MarkdownInputPrivacy.of(context)?.enableIMEPersonalizedLearning ??
            true,
        selectAllOnFocus: false,
        inputFormatters: const [_MarkdownTableCellInputFormatter()],
        decoration: null,
      ),
    );
    final body = active
        ? Stack(
            children: [
              Opacity(opacity: 0, child: rendered),
              Positioned.fill(
                child: Align(alignment: Alignment.topCenter, child: editor),
              ),
            ],
          )
        : rendered;
    return Listener(
      onPointerDown: (event) {
        if (event.buttons == kPrimaryButton) {
          widget.interactions?.beginPointer(widget.block);
        }
      },
      onPointerUp: (_) => widget.interactions?.endPointer(widget.block),
      onPointerCancel: (_) => widget.interactions?.endPointer(widget.block),
      child: GestureDetector(
        key: ValueKey(
          'table-cell-${widget.block.sourceStart}-$rowIndex-$column',
        ),
        behavior: HitTestBehavior.opaque,
        onTapUp: active
            ? null
            : (details) => _activateCell(
                rowIndex,
                column,
                position: _sourcePositionForTap(
                  projection,
                  renderedKey,
                  details.globalPosition,
                ),
              ),
        onSecondaryTapDown: (details) =>
            _showCellMenu(rowIndex, column, details.globalPosition),
        child: DecoratedBox(
          decoration: decoration ?? const BoxDecoration(),
          child: ColoredBox(
            color: active ? widget.activeCellColor : Colors.transparent,
            child: Padding(padding: padding, child: body),
          ),
        ),
      ),
    );
  }

  Widget _renderedCell(
    _TableCellProjection projection,
    TextAlign textAlign, {
    required Key key,
  }) {
    return Text.rich(
      projection.span,
      key: key,
      textAlign: textAlign,
      textScaler: MediaQuery.textScalerOf(context),
      softWrap: true,
      strutStyle: StrutStyle.disabled,
    );
  }

  TextAlign _textAlignForColumn(int column, MarkdownStyleSheet sheet) {
    if (column >= widget.table.rows[1].cells.length) {
      return TextAlign.left;
    }
    final marker = widget.table.rows[1].cells[column].textOf(widget.document);
    if (marker.startsWith(':') && marker.endsWith(':')) {
      return TextAlign.center;
    }
    if (marker.endsWith(':')) return TextAlign.right;
    return TextAlign.left;
  }

  TextPosition _sourcePositionForTap(
    _TableCellProjection projection,
    GlobalKey renderedKey,
    Offset globalPosition,
  ) {
    final paragraph = renderedKey.currentContext?.findRenderObject();
    if (paragraph is! RenderParagraph) return const TextPosition(offset: 0);
    final position = paragraph.getPositionForOffset(
      paragraph.globalToLocal(globalPosition),
    );
    // Keep the hit-test affinity: replacing an end click with a downstream
    // offset makes the native caret jump when the user clicks it again.
    return TextPosition(
      offset: projection.sourceOffsetAt(position.offset),
      affinity: position.affinity,
    );
  }

  void _activateCell(
    int rowIndex,
    int column, {
    required TextPosition position,
  }) {
    if (rowIndex == 1 || rowIndex >= widget.table.rows.length) return;
    var target = (rowIndex: rowIndex, column: column);
    if (column >= widget.table.rows[rowIndex].cells.length) {
      final materialized = widget.interactions?.materializeCell(
        widget.block,
        rowIndex,
        column,
      );
      if (materialized == null) return;
      target = materialized;
      position = const TextPosition(offset: 0);
    }
    _cellFocus.unfocus();
    _editOrigin = Object();
    widget.interactions?.startEditing(
      widget.block,
      target.rowIndex,
      target.column,
      position,
    );
    setState(() {
      _active = (rowIndex: target.rowIndex, column: target.column);
      _setCellValueForTarget(position: position);
    });
    _requestCellFocus();
  }

  void _setTarget(({int rowIndex, int column}) target) {
    _cellFocus.unfocus();
    _editOrigin = Object();
    _active = (rowIndex: target.rowIndex, column: target.column);
    _setCellValueForTarget(position: const TextPosition(offset: 0));
    if (mounted) setState(() {});
    _requestCellFocus();
  }

  void _setCellValueForTarget({required TextPosition position}) {
    final active = _active;
    final row = active == null || active.rowIndex >= widget.table.rows.length
        ? null
        : widget.table.rows[active.rowIndex];
    final cell = row == null || active!.column >= row.cells.length
        ? null
        : row.cells[active.column];
    final text = cell?.textOf(widget.document) ?? '';
    _syncingCell = true;
    _cellController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(
        offset: position.offset.clamp(0, text.length),
        affinity: position.affinity,
      ),
    );
    _lastCellText = text;
    _syncingCell = false;
  }

  void _syncActiveCell() {
    final active = _active;
    if (active == null || active.rowIndex >= widget.table.rows.length) return;
    final row = widget.table.rows[active.rowIndex];
    if (active.column >= row.cells.length) return;
    final cell = row.cells[active.column];
    if (_cellValueMatchesDocument(cell)) return;
    final text = cell.textOf(widget.document);
    final globalSelection = widget.selection;
    final selection = TextSelection(
      baseOffset: (globalSelection.baseOffset - cell.contentStart).clamp(
        0,
        text.length,
      ),
      extentOffset: (globalSelection.extentOffset - cell.contentStart).clamp(
        0,
        text.length,
      ),
      affinity: globalSelection.affinity,
      isDirectional: globalSelection.isDirectional,
    );
    final globalComposing = widget.composing;
    final composing =
        globalComposing.isValid &&
            globalComposing.isNormalized &&
            globalComposing.start >= cell.contentStart &&
            globalComposing.end <= cell.contentEnd
        ? TextRange(
            start: globalComposing.start - cell.contentStart,
            end: globalComposing.end - cell.contentStart,
          )
        : TextRange.empty;
    final nextValue = TextEditingValue(
      text: text,
      selection: selection,
      composing: composing,
    );
    if (_cellController.value == nextValue) return;
    _syncingCell = true;
    _cellController.value = nextValue;
    _lastCellText = text;
    _syncingCell = false;
  }

  bool _cellValueMatchesDocument(MarkdownTableCell cell) {
    if (cell.start < 0 ||
        cell.end > widget.document.length ||
        cell.start > cell.end ||
        widget.document.substring(cell.start, cell.end) !=
            ' ${_cellController.text} ') {
      return false;
    }
    final valueStart = cell.start + 1;
    final local = _cellController.value;
    final expectedSelection = TextSelection(
      baseOffset: valueStart + local.selection.baseOffset,
      extentOffset: valueStart + local.selection.extentOffset,
      affinity: local.selection.affinity,
      isDirectional: local.selection.isDirectional,
    );
    final localComposing = local.composing;
    final expectedComposing =
        localComposing.isValid && localComposing.isNormalized
        ? TextRange(
            start: valueStart + localComposing.start,
            end: valueStart + localComposing.end,
          )
        : TextRange.empty;
    return widget.selection == expectedSelection &&
        widget.composing == expectedComposing;
  }

  void _handleCellValue() {
    if (_syncingCell) return;
    final active = _active;
    if (active == null) return;
    final textChanged = _cellController.text != _lastCellText;
    final valid = widget.interactions?.editCell(
      widget.block,
      active.rowIndex,
      active.column,
      _cellController.value,
      _editOrigin,
      textChanged,
    );
    _lastCellText = _cellController.text;
    if (valid == false) _exitToRaw();
  }

  void _handleSourceValue() {
    if (_syncingSource || !widget.sourceEditing) return;
    if (_sourceController.text != widget.block.source) {
      _verticalCaretRun = null;
      _verticalCaretEditable = null;
    }
    final valid = widget.interactions?.editSource(
      widget.block,
      _sourceController.value,
      _sourceEditOrigin,
    );
    if (valid == false) _sourceFocus.unfocus();
  }

  KeyEventResult _handleSourceKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final commandPressed = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (commandPressed && event.logicalKey == LogicalKeyboardKey.keyZ) {
      widget.interactions?.history(redo: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _exitSourceAt(
        widget.block.sourceStart + _sourceController.selection.extentOffset,
      );
      return KeyEventResult.handled;
    }
    final selection = _sourceController.selection;
    final modifiedNavigation =
        commandPressed || keyboard.isAltPressed || keyboard.isShiftPressed;
    if (selection.isCollapsed &&
        !modifiedNavigation &&
        event.logicalKey == LogicalKeyboardKey.arrowLeft &&
        selection.extentOffset <= 1) {
      _exitSourceAt(widget.block.sourceStart);
      return KeyEventResult.handled;
    }
    if (selection.isCollapsed &&
        !modifiedNavigation &&
        event.logicalKey == LogicalKeyboardKey.arrowRight &&
        selection.extentOffset >= _sourceController.text.length - 1) {
      _exitSourceAt(widget.block.sourceEnd);
      return KeyEventResult.handled;
    }
    final verticalDirection = event.logicalKey == LogicalKeyboardKey.arrowUp
        ? -1
        : event.logicalKey == LogicalKeyboardKey.arrowDown
        ? 1
        : 0;
    if (verticalDirection == 0) {
      _verticalCaretRun = null;
      _verticalCaretEditable = null;
    }
    if (verticalDirection != 0 && !commandPressed && !keyboard.isAltPressed) {
      final target = _sourcePositionOneVisualLine(up: verticalDirection < 0);
      if (target == null) {
        if (keyboard.isShiftPressed) {
          _sourceController.selection = TextSelection(
            baseOffset: selection.baseOffset,
            extentOffset: verticalDirection < 0
                ? 0
                : _sourceController.text.length,
            isDirectional: true,
          );
        } else if (selection.isCollapsed) {
          _exitSourceAt(
            verticalDirection < 0
                ? widget.block.sourceStart
                : widget.block.sourceEnd,
          );
        } else {
          _sourceController.selection = TextSelection.collapsed(
            offset: verticalDirection < 0 ? 0 : _sourceController.text.length,
          );
        }
        return KeyEventResult.handled;
      }
      _sourceController.selection = TextSelection(
        baseOffset: keyboard.isShiftPressed
            ? selection.baseOffset
            : target.offset,
        extentOffset: target.offset,
        affinity: target.affinity,
        isDirectional: keyboard.isShiftPressed,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  TextPosition? _sourcePositionOneVisualLine({required bool up}) {
    final renderEditable = _sourceRenderEditable();
    if (renderEditable == null || !renderEditable.hasSize) return null;
    final selection = _sourceController.selection;
    var run = _verticalCaretRun;
    if (run == null ||
        !identical(_verticalCaretEditable, renderEditable) ||
        !run.isValid ||
        run.current.offset != selection.extentOffset) {
      run = renderEditable.startVerticalCaretMovement(
        TextPosition(
          offset: selection.extentOffset,
          affinity: selection.affinity,
        ),
      );
      _verticalCaretRun = run;
      _verticalCaretEditable = renderEditable;
    }
    final moved = up ? run.movePrevious() : run.moveNext();
    return moved ? run.current : null;
  }

  RenderEditable? _sourceRenderEditable() {
    final root = _sourceEditorHostKey.currentContext?.findRenderObject();
    RenderEditable? editable;
    void findEditable(RenderObject child) {
      if (editable != null) return;
      if (child is RenderEditable &&
          child.plainText == _sourceController.text) {
        editable = child;
        return;
      }
      child.visitChildren(findEditable);
    }

    if (root is RenderEditable && root.plainText == _sourceController.text) {
      editable = root;
    } else {
      root?.visitChildren(findEditable);
    }
    return editable;
  }

  void _exitSourceAt(int documentOffset) {
    _verticalCaretRun = null;
    _verticalCaretEditable = null;
    _sourceFocus.unfocus();
    widget.interactions?.exit(documentOffset);
  }

  KeyEventResult _handleCellKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final commandPressed = keyboard.isMetaPressed || keyboard.isControlPressed;
    if (commandPressed && event.logicalKey == LogicalKeyboardKey.keyZ) {
      widget.interactions?.history(redo: keyboard.isShiftPressed);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _exitToRaw();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && !commandPressed) {
      _runCommand(
        _active!.rowIndex,
        _active!.column,
        keyboard.isShiftPressed
            ? MarkdownEditingCommand.shiftTab
            : MarkdownEditingCommand.tab,
      );
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _runCommand(int rowIndex, int column, MarkdownEditingCommand command) {
    if (_active == null) _editOrigin = Object();
    final target = widget.interactions?.runCommand(
      widget.block,
      rowIndex,
      column,
      command,
    );
    if (target != null) _setTarget(target);
  }

  Future<void> _showCellMenu(
    int rowIndex,
    int column,
    Offset globalPosition,
  ) async {
    final restoreCellFocus = _cellFocus.hasFocus;
    if (!mounted) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pasteRegion = _cellPasteKey.currentState;
    final pasteController = MarkdownPasteScope.maybeControllerOf(context);
    final activeCell =
        _active?.rowIndex == rowIndex && _active?.column == column;
    final row = widget.table.rows[rowIndex];
    final cell = column < row.cells.length ? row.cells[column] : null;
    final pasteTarget = activeCell
        ? pasteRegion?.captureTarget()
        : cell == null
        ? null
        : MarkdownPasteTarget(
            selection: TextSelection.collapsed(
              offset: cell.contentStart == cell.contentEnd
                  ? cell.editingOffset
                  : cell.contentEnd,
            ),
            area: MarkdownPasteArea.tableCell,
            containerStart: widget.block.sourceStart,
            row: rowIndex,
            column: column,
          );
    final canPaste = pasteController != null && pasteTarget != null;
    final command = await showMenu<Object>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(globalPosition.dx, globalPosition.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (canPaste)
          MarkdownMenuPresentation.entry(
            context,
            'paste',
            'Paste',
            Icons.content_paste_outlined,
          ),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableInsertRowAbove,
          'Insert row above',
          Icons.vertical_align_top_outlined,
        ),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableInsertRowBelow,
          'Insert row below',
          Icons.vertical_align_bottom_outlined,
        ),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableDeleteRow,
          'Delete row',
          Icons.delete_outline,
          enabled: rowIndex >= 2,
        ),
        const PopupMenuDivider(),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableInsertColumnLeft,
          'Insert column left',
          Icons.first_page_outlined,
        ),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableInsertColumnRight,
          'Insert column right',
          Icons.last_page_outlined,
        ),
        MarkdownMenuPresentation.entry(
          context,
          MarkdownEditingCommand.tableDeleteColumn,
          'Delete column',
          Icons.delete_outline,
          enabled: widget.table.columnCount > 1,
        ),
      ],
    );
    if (!mounted || command == null) {
      if (restoreCellFocus) _requestCellFocus();
      return;
    }
    if (command == 'paste') {
      if (activeCell) {
        await pasteRegion?.paste(target: pasteTarget);
      } else if (pasteController != null && pasteTarget != null) {
        await pasteController.paste(
          pasteTarget,
          pasteText: (text, range) {
            if (!mounted || rowIndex >= widget.table.rows.length) return false;
            final latestCells = widget.table.rows[rowIndex].cells;
            if (column >= latestCells.length) return false;
            final latest = latestCells[column];
            final oldText = latest.textOf(widget.document);
            final origin = oldText.isEmpty
                ? latest.editingOffset
                : latest.contentStart;
            final start = range.start - origin;
            final end = range.end - origin;
            if (start < 0 || end > oldText.length) return false;
            final before = TextEditingValue(
              text: oldText,
              selection: TextSelection(baseOffset: start, extentOffset: end),
            );
            final after = before.replaced(
              TextRange(start: start, end: end),
              text,
            );
            final formatted = const _MarkdownTableCellInputFormatter()
                .formatEditUpdate(before, after);
            if (formatted == before) return false;
            return widget.interactions?.editCell(
                  widget.block,
                  rowIndex,
                  column,
                  formatted,
                  Object(),
                  true,
                ) ??
                false;
          },
        );
      }
      return;
    }
    _runCommand(rowIndex, column, command as MarkdownEditingCommand);
  }

  void _exitToRaw() {
    final active = _active;
    if (active == null) return;
    final row = active.rowIndex < widget.table.rows.length
        ? widget.table.rows[active.rowIndex]
        : null;
    final cell = row != null && active.column < row.cells.length
        ? row.cells[active.column]
        : null;
    final documentOffset = cell == null
        ? widget.block.sourceStart
        : cell.contentStart +
              _cellController.selection.extentOffset.clamp(
                0,
                cell.contentEnd - cell.contentStart,
              );
    _cellFocus.unfocus();
    setState(() => _active = null);
    widget.interactions?.exit(documentOffset);
  }

  void _requestCellFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _active == null) return;
      final selection = _cellController.selection;
      if (!selection.isCollapsed) {
        _cellController.selection = TextSelection.collapsed(
          offset: selection.extentOffset,
        );
      }
      _cellFocus.requestFocus();
    });
  }

  void _requestSourceFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.sourceEditing) _sourceFocus.requestFocus();
    });
  }

  Widget _addButton({
    required Key key,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        key: key,
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        elevation: 1,
        child: InkResponse(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: const SizedBox(
            width: 24,
            height: 24,
            child: Icon(Icons.add, size: 16),
          ),
        ),
      ),
    );
  }
}

class _MarkdownTableCellInputFormatter extends TextInputFormatter {
  const _MarkdownTableCellInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.contains('\n') || newValue.text.contains('\r')) {
      return oldValue;
    }
    for (var offset = 0; offset < newValue.text.length; offset++) {
      if (newValue.text.codeUnitAt(offset) != 0x7c) continue;
      var slashes = 0;
      for (
        var index = offset - 1;
        index >= 0 && newValue.text.codeUnitAt(index) == 0x5c;
        index--
      ) {
        slashes++;
      }
      if (slashes.isEven) return oldValue;
    }
    return newValue;
  }
}

class _ForwardingTextAction<T extends Intent> extends Action<T> {
  @override
  bool get isActionEnabled => callingAction?.isActionEnabled ?? false;

  @override
  Object? invoke(T intent) => callingAction?.invoke(intent);

  @override
  bool consumesKey(T intent) => callingAction?.consumesKey(intent) ?? false;
}

class _InteractiveCalloutPreview extends StatefulWidget {
  const _InteractiveCalloutPreview({
    required this.block,
    required this.selection,
    required this.composing,
    required this.editing,
    required this.styleSheet,
    required this.accent,
    required this.backgroundColor,
    required this.borderSide,
    required this.borderRadius,
    required this.interactions,
    required this.imageResolver,
    this.mediaTypeResolver,
    this.videoBuilder,
    this.audioBuilder,
    required this.onInlineInteraction,
    required this.highlightColor,
  });

  final MarkdownBlock block;
  final TextSelection selection;
  final TextRange composing;
  final bool editing;
  final MarkdownStyleSheet? styleSheet;
  final Color accent;
  final Color backgroundColor;
  final BorderSide borderSide;
  final BorderRadius borderRadius;
  final _CalloutInteractions? interactions;
  final LiveMarkdownImageResolver imageResolver;
  final LiveMarkdownMediaTypeResolver? mediaTypeResolver;
  final LiveMarkdownVideoBuilder? videoBuilder;
  final LiveMarkdownAudioBuilder? audioBuilder;
  final MarkdownInlineInteraction? onInlineInteraction;
  final Color highlightColor;

  @override
  State<_InteractiveCalloutPreview> createState() =>
      _InteractiveCalloutPreviewState();
}

class _InteractiveCalloutPreviewState
    extends State<_InteractiveCalloutPreview> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late final FocusNode _titleFocus;
  late final FocusNode _bodyFocus;
  bool _syncing = false;
  CalloutEditingField? _activeField;
  Object _titleOrigin = Object();
  Object _bodyOrigin = Object();
  final GlobalKey _titlePreviewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController()..addListener(_handleTitle);
    _bodyController = TextEditingController()..addListener(_handleBody);
    _titleFocus = FocusNode(onKeyEvent: _handleKey);
    _bodyFocus = FocusNode(onKeyEvent: _handleKey);
    _syncValues();
  }

  @override
  void didUpdateWidget(covariant _InteractiveCalloutPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncValues();
    if (!widget.editing) {
      _activeField = null;
      _titleFocus.unfocus();
      _bodyFocus.unfocus();
    }
  }

  @override
  void dispose() {
    _titleController.removeListener(_handleTitle);
    _bodyController.removeListener(_handleBody);
    _titleController.clear();
    _bodyController.clear();
    _titleController.dispose();
    _bodyController.dispose();
    _titleFocus.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _syncValues() {
    final parts = CalloutSourceParts.parse(widget.block);
    _syncing = true;
    void sync(
      TextEditingController controller,
      String text,
      CalloutEditingField field,
      int start,
      int end,
      int Function(int) localOffset,
    ) {
      final global = widget.selection;
      final active =
          _activeField == field &&
          global.isValid &&
          global.start >= start &&
          global.end <= end;
      final selection = active
          ? TextSelection(
              baseOffset: localOffset(global.baseOffset),
              extentOffset: localOffset(global.extentOffset),
              affinity: global.affinity,
              isDirectional: global.isDirectional,
            )
          : TextSelection(
              baseOffset: controller.selection.baseOffset.clamp(0, text.length),
              extentOffset: controller.selection.extentOffset.clamp(
                0,
                text.length,
              ),
            );
      final composing = widget.composing;
      final next = TextEditingValue(
        text: text,
        selection: selection,
        composing:
            active &&
                composing.isValid &&
                composing.start >= start &&
                composing.end <= end
            ? TextRange(
                start: localOffset(composing.start),
                end: localOffset(composing.end),
              )
            : TextRange.empty,
      );
      if (controller.value != next) controller.value = next;
    }

    sync(
      _titleController,
      parts.title,
      CalloutEditingField.title,
      parts.titleStart,
      parts.titleEnd,
      (offset) => (offset - parts.titleStart).clamp(0, parts.title.length),
    );
    sync(
      _bodyController,
      parts.body,
      CalloutEditingField.body,
      parts.bodyStart,
      widget.block.sourceEnd,
      parts.bodyLocalOffset,
    );
    _syncing = false;
  }

  void _activate(CalloutEditingField field, int offset) {
    _activeField = field;
    if (field == CalloutEditingField.title) {
      _titleOrigin = Object();
    } else {
      _bodyOrigin = Object();
    }
    widget.interactions?.startEditing(widget.block, field, offset);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final focus = field == CalloutEditingField.title
          ? _titleFocus
          : _bodyFocus;
      focus.requestFocus();
      final controller = field == CalloutEditingField.title
          ? _titleController
          : _bodyController;
      controller.selection = TextSelection.collapsed(
        offset: offset.clamp(0, controller.text.length),
      );
    });
  }

  void _handleTitle() {
    if (_syncing) return;
    widget.interactions?.edit(
      widget.block,
      CalloutEditingField.title,
      _titleController.value,
      _titleOrigin,
    );
  }

  void _handleBody() {
    if (_syncing) return;
    widget.interactions?.edit(
      widget.block,
      CalloutEditingField.body,
      _bodyController.value,
      _bodyOrigin,
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight &&
        key != LogicalKeyboardKey.arrowUp &&
        key != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    final parts = CalloutSourceParts.parse(widget.block);
    final controller = node == _titleFocus ? _titleController : _bodyController;
    final localOffset = controller.selection.extentOffset;
    final documentOffset = node == _titleFocus
        ? parts.titleStart + localOffset
        : parts.bodyDocumentOffset(localOffset);
    widget.interactions?.revealSource(widget.block, documentOffset);
    return KeyEventResult.handled;
  }

  int _textOffsetAt(
    Offset point,
    String text,
    TextStyle? style,
    double maxWidth,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
    )..layout(maxWidth: maxWidth);
    final offset = painter.getPositionForOffset(point).offset;
    painter.dispose();
    return offset;
  }

  @override
  Widget build(BuildContext context) {
    final parts = CalloutSourceParts.parse(widget.block);
    final kind = parts.kind;
    final title = parts.title.trim().isNotEmpty
        ? parts.title
        : '${kind[0].toUpperCase()}${kind.substring(1)}';
    final body = parts.body.trimRight();
    // Resolve inherited properties once: Text and TextField otherwise use
    // different theme defaults (bodyMedium versus bodyLarge).
    final bodyStyle = DefaultTextStyle.of(context).style
        .merge(widget.styleSheet?.p ?? Theme.of(context).textTheme.bodyMedium);
    final titleStyle = bodyStyle.copyWith(
      color: widget.accent,
      fontWeight: FontWeight.w700,
    );
    final textScaler = MediaQuery.textScalerOf(context);
    // Even a collapsed InputDecoration adds a font-dependent baseline offset.
    // These inline editors need the same text origin as the preview.
    final titleEditor = MarkdownPasteRegion(
      area: MarkdownPasteArea.calloutTitle,
      containerStart: widget.block.sourceStart,
      toDocumentOffset: (offset) => parts.titleStart + offset,
      field: TextField(
        readOnly: MarkdownInputPrivacy.of(context)?.readOnly ?? false,
        key: ValueKey('callout-title-editor-${widget.block.sourceStart}'),
        autocorrect: MarkdownInputPrivacy.of(context)?.autocorrect ?? true,
        enableSuggestions:
            MarkdownInputPrivacy.of(context)?.enableSuggestions ?? true,
        enableIMEPersonalizedLearning:
            MarkdownInputPrivacy.of(context)?.enableIMEPersonalizedLearning ??
            true,
        contextMenuBuilder: markdownPasteContextMenu,
        controller: _titleController,
        contentInsertionConfiguration: markdownContentInsertionConfiguration(
          context,
          _titleController,
        ),
        focusNode: _titleFocus,
        minLines: 1,
        maxLines: 1,
        style: titleStyle,
        cursorHeight: _naturalGlyphHeight(titleStyle, textScaler),
        selectAllOnFocus: false,
        scrollPadding: EdgeInsets.zero,
        strutStyle: StrutStyle.disabled,
        decoration: null,
      ),
    );
    final bodyEditor = MarkdownPasteRegion(
      area: MarkdownPasteArea.calloutBody,
      containerStart: widget.block.sourceStart,
      toDocumentOffset: parts.bodyDocumentOffset,
      field: TextField(
        readOnly: MarkdownInputPrivacy.of(context)?.readOnly ?? false,
        key: ValueKey('callout-body-editor-${widget.block.sourceStart}'),
        autocorrect: MarkdownInputPrivacy.of(context)?.autocorrect ?? true,
        enableSuggestions:
            MarkdownInputPrivacy.of(context)?.enableSuggestions ?? true,
        enableIMEPersonalizedLearning:
            MarkdownInputPrivacy.of(context)?.enableIMEPersonalizedLearning ??
            true,
        contextMenuBuilder: markdownPasteContextMenu,
        controller: _bodyController,
        contentInsertionConfiguration: markdownContentInsertionConfiguration(
          context,
          _bodyController,
        ),
        focusNode: _bodyFocus,
        minLines: 1,
        maxLines: null,
        style: bodyStyle,
        cursorHeight: _naturalGlyphHeight(bodyStyle, textScaler),
        selectAllOnFocus: false,
        scrollPadding: EdgeInsets.zero,
        strutStyle: StrutStyle(
          fontFamily: bodyStyle.fontFamily,
          fontSize: bodyStyle.fontSize,
          height: bodyStyle.height,
          leading: 0,
          forceStrutHeight: true,
        ),
        decoration: null,
      ),
    );
    final titleActive =
        _activeField == CalloutEditingField.title && widget.editing;
    final titleProjection = title.contains('![')
        ? _TableCellProjection.build(
            context,
            source: title,
            sourceOffset: parts.titleStart,
            style: titleStyle,
            sheet:
                widget.styleSheet ??
                MarkdownStyleSheet.fromTheme(Theme.of(context)),
            syntaxColor: titleStyle.color ?? widget.accent,
            highlightColor: widget.highlightColor,
            onInlineInteraction: widget.onInlineInteraction,
            imageResolver: widget.imageResolver,
            mediaTypeResolver: widget.mediaTypeResolver,
          )
        : null;
    final renderedTitle = LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) {
          final paragraph = _titlePreviewKey.currentContext?.findRenderObject();
          final offset = titleProjection != null && paragraph is RenderParagraph
              ? titleProjection.sourceOffsetAt(
                  paragraph
                      .getPositionForOffset(
                        paragraph.globalToLocal(details.globalPosition),
                      )
                      .offset,
                )
              : _textOffsetAt(
                  details.localPosition,
                  title,
                  titleStyle,
                  constraints.maxWidth,
                );
          _activate(CalloutEditingField.title, offset);
        },
        child: SizedBox(
          width: double.infinity,
          child: titleProjection == null
              ? Text(title, style: titleStyle)
              : Text.rich(titleProjection.span, key: _titlePreviewKey),
        ),
      ),
    );
    final titleSlot = Stack(
      children: [
        IgnorePointer(
          ignoring: titleActive,
          child: Opacity(opacity: titleActive ? 0 : 1, child: renderedTitle),
        ),
        if (titleActive) Positioned.fill(child: titleEditor),
      ],
    );
    final bodyActive =
        _activeField == CalloutEditingField.body && widget.editing;
    final renderedBody = LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) => _activate(
          CalloutEditingField.body,
          _textOffsetAt(
            details.localPosition,
            body,
            bodyStyle,
            constraints.maxWidth,
          ),
        ),
        child: SizedBox(
          width: double.infinity,
          child: MarkdownBody(
            data: body,
            imageBuilder: (uri, title, alt) {
              // MarkdownBody normalizes a destination into Uri. Resolve back
              // to the original reference so custom media IDs behave exactly
              // as they do in the main editor and table projections.
              var destination = uri.toString();
              void findOriginal(Iterable<MarkdownInlineNode> nodes) {
                for (final node in nodes) {
                  if (node.kind == MarkdownInlineKind.image &&
                      node.destinationRange != null) {
                    final original = unescapeMarkdownMedia(
                      node.destinationRange!.textIn(body),
                    );
                    if (Uri.tryParse(original)?.toString() == uri.toString()) {
                      destination = original;
                    }
                  }
                  findOriginal(node.inlines);
                }
              }

              for (final line
                  in const MarkdownSyntaxParser().parse(body).lines) {
                findOriginal(line.inlines);
              }
              final type = resolveLiveMarkdownMediaType(
                destination,
                resolver: widget.mediaTypeResolver,
              );
              if (type == LiveMarkdownMediaType.video) {
                return SizedBox(
                  width: _imageSlotMaxWidth,
                  height: _imageSlotHeight,
                  child:
                      widget.videoBuilder?.call(
                        context,
                        destination,
                        alt ?? '',
                      ) ??
                      const Icon(Icons.play_circle_outline),
                );
              }
              if (type == LiveMarkdownMediaType.audio) {
                return SizedBox(
                  width: _audioSlotMaxWidth,
                  height: _audioSlotHeight,
                  child:
                      widget.audioBuilder?.call(
                        context,
                        destination,
                        alt ?? '',
                      ) ??
                      const Icon(Icons.graphic_eq_rounded),
                );
              }
              return Image(
                image: widget.imageResolver(destination),
                width: _imageSlotMaxWidth,
                height: _imageSlotHeight,
                fit: BoxFit.contain,
                semanticLabel: alt,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              );
            },
            styleSheet:
                (widget.styleSheet ??
                        MarkdownStyleSheet.fromTheme(Theme.of(context)))
                    .copyWith(
                      p: bodyStyle,
                      blockSpacing: 0,
                      pPadding: EdgeInsets.zero,
                    ),
            shrinkWrap: true,
          ),
        ),
      ),
    );
    final bodySlot = Stack(
      children: [
        IgnorePointer(
          ignoring: bodyActive,
          child: Opacity(opacity: bodyActive ? 0 : 1, child: renderedBody),
        ),
        if (bodyActive) Positioned.fill(child: bodyEditor),
      ],
    );

    final callout = DecoratedBox(
      decoration: BoxDecoration(
        color: widget.backgroundColor,
        border: Border(left: widget.borderSide),
        borderRadius: widget.borderRadius,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: _calloutVerticalPadding,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline_rounded,
                  key: ValueKey('callout-icon-${widget.block.sourceStart}'),
                  size: 18,
                  color: widget.accent,
                ),
                const SizedBox(width: 7),
                Expanded(child: titleSlot),
              ],
            ),
            if (body.isNotEmpty) ...[
              const SizedBox(height: _calloutBodyGap),
              bodySlot,
            ],
          ],
        ),
      ),
    );
    return DefaultSelectionStyle(
      selectionColor:
          Theme.of(context).textSelectionTheme.selectionColor ??
          widget.accent.withValues(alpha: 0.28),
      cursorColor:
          Theme.of(context).textSelectionTheme.cursorColor ?? widget.accent,
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kPrimaryButton) {
            widget.interactions?.beginPointer(widget.block);
          }
        },
        onPointerUp: (_) => widget.interactions?.endPointer(widget.block),
        onPointerCancel: (_) => widget.interactions?.endPointer(widget.block),
        child: callout,
      ),
    );
  }
}

class CalloutSourceParts {
  const CalloutSourceParts({
    required this.kind,
    required this.title,
    required this.titleStart,
    required this.titleEnd,
    required this.body,
    required this.bodyStart,
    required this.bodyLineStarts,
  });

  factory CalloutSourceParts.parse(MarkdownBlock block) {
    final source = block.source;
    final firstBreak = source.indexOf('\n');
    final headerEnd = firstBreak < 0 ? source.length : firstBreak;
    final header = source.substring(0, headerEnd);
    final match = RegExp(r'^\s*>\s*\[!([^\]]+)\][+-]?\s*(.*)$')
        .firstMatch(header);
    final title = match?.group(2) ?? '';
    final titleStart = block.sourceStart + header.length - title.length;
    final bodyStart = firstBreak < 0
        ? block.sourceEnd
        : block.sourceStart + firstBreak + 1;
    final rawBody = firstBreak < 0 ? '' : source.substring(firstBreak + 1);
    final bodyLines = rawBody.split('\n');
    final starts = <int>[];
    var documentCursor = bodyStart;
    final visible = <String>[];
    for (final line in bodyLines) {
      final prefix = RegExp(r'^\s*>\s?').firstMatch(line);
      starts.add(documentCursor + (prefix?.end ?? 0));
      visible.add(line.substring(prefix?.end ?? 0));
      documentCursor += line.length + 1;
    }
    return CalloutSourceParts(
      kind: match?.group(1) ?? 'note',
      title: title,
      titleStart: titleStart,
      titleEnd: titleStart + title.length,
      body: visible.join('\n'),
      bodyStart: bodyStart,
      bodyLineStarts: starts,
    );
  }

  final String kind;
  final String title;
  final int titleStart;
  final int titleEnd;
  final String body;
  final int bodyStart;
  final List<int> bodyLineStarts;

  int bodyDocumentOffset(int localOffset) {
    final before = body.substring(0, localOffset.clamp(0, body.length).toInt());
    final line = '\n'.allMatches(before).length;
    final lineStart = before.lastIndexOf('\n') + 1;
    if (bodyLineStarts.isEmpty) return bodyStart;
    return bodyLineStarts[line.clamp(0, bodyLineStarts.length - 1).toInt()] +
        before.length -
        lineStart;
  }

  int bodyLocalOffset(int documentOffset) {
    final lines = body.split('\n');
    var localStart = 0;
    for (var index = 0; index < bodyLineStarts.length; index++) {
      final length = lines[index].length;
      if (documentOffset <= bodyLineStarts[index] + length) {
        return localStart +
            (documentOffset - bodyLineStarts[index]).clamp(0, length);
      }
      localStart += length + 1;
    }
    return body.length;
  }
}
