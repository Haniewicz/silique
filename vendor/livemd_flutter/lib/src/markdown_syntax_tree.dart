/// A half-open UTF-16 code-unit range in the original Markdown source.
///
/// Dart string offsets and Flutter text editing offsets are both UTF-16 code
/// units, so these values can be passed to a Flutter text controller without
/// conversion.
class SourceRange {
  /// Creates a range with nonnegative [start] and [end] at or after [start].
  const SourceRange(this.start, this.end)
    : assert(start >= 0),
      assert(end >= start);

  /// Inclusive source offset.
  final int start;

  /// Exclusive source offset.
  final int end;

  /// Number of UTF-16 code units, not user-perceived characters.
  int get length => end - start;

  /// Whether the range is empty.
  bool get isCollapsed => start == end;

  /// Whether [offset] lies in the range; [includeEnd] also accepts its end.
  bool contains(int offset, {bool includeEnd = false}) =>
      offset >= start && (offset < end || (includeEnd && offset == end));

  /// Extracts the exact source slice; throws if this range exceeds [source].
  String textIn(String source) => source.substring(start, end);

  @override
  bool operator ==(Object other) =>
      other is SourceRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SourceRange($start, $end)';
}

/// Common range information exposed by every node in a Markdown syntax tree.
abstract interface class MarkdownSyntaxNode {
  /// Entire construct, including syntax delimiters.
  SourceRange get fullRange;

  /// Content within the construct's outer delimiters or block prefix.
  SourceRange get contentRange;

  /// Source slices occupied by recognized syntax markers.
  List<SourceRange> get delimiterRanges;

  /// Nested syntax nodes in source order.
  List<MarkdownSyntaxNode> get children;
}

/// Recognized physical-line forms; complex blocks are scanned separately.
enum MarkdownLineKind {
  blank,
  paragraph,
  atxHeading,
  blockquote,
  unorderedListItem,
  orderedListItem,
  taskListItem,
}

/// Complete inline constructs recognized by [MarkdownSyntaxParser].
enum MarkdownInlineKind {
  text,
  bold,
  italic,
  strikethrough,
  highlight,
  codeSpan,
  link,
  wikiLink,
  image,
  /// Inline `<span style="font-size:Npx">…</span>` run with a stored size.
  fontSize,
}

/// A lossless Markdown document rooted in [source].
class MarkdownSyntaxTree implements MarkdownSyntaxNode {
  MarkdownSyntaxTree._({
    required this.source,
    required List<MarkdownLineNode> lines,
  }) : lines = List.unmodifiable(lines),
       fullRange = SourceRange(0, source.length),
       contentRange = SourceRange(0, source.length);

  /// Unmodified Markdown used to produce this tree.
  final String source;

  /// Immutable physical-line nodes in source order.
  final List<MarkdownLineNode> lines;

  @override
  final SourceRange fullRange;

  @override
  final SourceRange contentRange;

  @override
  List<SourceRange> get delimiterRanges => const [];

  @override
  List<MarkdownSyntaxNode> get children => lines;

  /// Reads an exact source range without stripping or unescaping markers.
  String textOf(SourceRange range) => range.textIn(source);
}

/// One physical source line. [fullRange] includes its CR/LF terminator, while
/// [contentRange] excludes both the terminator and any recognized block prefix.
class MarkdownLineNode implements MarkdownSyntaxNode {
  /// Creates a positioned line; supplied ranges refer to the full document.
  MarkdownLineNode({
    required this.kind,
    required this.fullRange,
    required this.contentRange,
    required this.prefixRange,
    required this.lineEndingRange,
    required List<SourceRange> delimiterRanges,
    required List<MarkdownInlineNode> inlines,
    this.headingLevel,
    this.marker,
    this.ordinal,
    this.taskChecked,
    this.taskMarkerRange,
  }) : delimiterRanges = List.unmodifiable(delimiterRanges),
       inlines = List.unmodifiable(inlines);

  /// Recognized block-prefix form for this line.
  final MarkdownLineKind kind;

  @override
  final SourceRange fullRange;

  @override
  final SourceRange contentRange;

  /// Everything before [contentRange], including indentation and separator
  /// whitespace. It is collapsed for ordinary paragraph lines.
  final SourceRange prefixRange;

  /// The exact `\n`, `\r\n`, or collapsed end-of-document range.
  final SourceRange lineEndingRange;

  @override
  final List<SourceRange> delimiterRanges;

  /// Immutable inline nodes belonging to this line.
  final List<MarkdownInlineNode> inlines;

  /// Set only for [MarkdownLineKind.atxHeading].
  final int? headingLevel;

  /// The source marker (`#`, `>`, `-`, `+`, `*`, `1.`, or `1)`).
  final String? marker;

  /// The parsed list number, without punctuation.
  final int? ordinal;

  /// `false` for `[ ]`, `true` for `[x]`/`[X]`, and null otherwise.
  final bool? taskChecked;

  /// The exact `[ ]`, `[x]`, or `[X]` range for a task item.
  final SourceRange? taskMarkerRange;

  @override
  List<MarkdownSyntaxNode> get children => inlines;
}

/// A formatted or literal inline source slice.
class MarkdownInlineNode implements MarkdownSyntaxNode {
  /// Creates a positioned inline construct with document-global ranges.
  MarkdownInlineNode({
    required this.kind,
    required this.fullRange,
    required this.contentRange,
    required List<SourceRange> delimiterRanges,
    List<MarkdownInlineNode> children = const [],
    this.destinationRange,
    this.titleRange,
    this.targetRange,
    this.aliasRange,
    this.fontSize,
  }) : delimiterRanges = List.unmodifiable(delimiterRanges),
       inlines = List.unmodifiable(children);

  /// The recognized formatting or literal-text form.
  final MarkdownInlineKind kind;

  @override
  final SourceRange fullRange;

  @override
  final SourceRange contentRange;

  @override
  final List<SourceRange> delimiterRanges;

  /// Immutable nested inline nodes, also exposed by [children].
  final List<MarkdownInlineNode> inlines;

  /// Markdown link or image destination, excluding optional angle brackets.
  final SourceRange? destinationRange;

  /// Markdown link or image title, excluding its quote or parenthesis
  /// delimiters.
  final SourceRange? titleRange;

  /// Wiki-link target (the part before `|`).
  final SourceRange? targetRange;

  /// Wiki-link alias (the part after `|`), when present.
  final SourceRange? aliasRange;

  /// Requested font size in logical pixels for a [MarkdownInlineKind.fontSize]
  /// run; always within 8–72.
  final double? fontSize;

  @override
  List<MarkdownSyntaxNode> get children => inlines;
}

/// A small, lossless scanner designed for live-preview decoration.
///
/// It intentionally accepts only complete inline constructs. Unsupported or
/// incomplete syntax remains a [MarkdownInlineKind.text] node, so editing does
/// not cause speculative formatting.
class MarkdownSyntaxParser {
  /// Creates a stateless syntax scanner.
  const MarkdownSyntaxParser();

  /// Scans [source] without changing it. Every returned range uses offsets
  /// into this exact string; reparse after text changes before using ranges.
  MarkdownSyntaxTree parse(String source) {
    final inlineParser = _InlineParser(source);
    final lines = <MarkdownLineNode>[];
    var lineStart = 0;

    for (var index = 0; index < source.length; index++) {
      if (source.codeUnitAt(index) != _lineFeed) continue;
      final logicalEnd =
          index > lineStart && source.codeUnitAt(index - 1) == _carriageReturn
          ? index - 1
          : index;
      lines.add(
        _parseLine(source, inlineParser, lineStart, logicalEnd, index + 1),
      );
      lineStart = index + 1;
    }

    if (lineStart < source.length) {
      lines.add(
        _parseLine(
          source,
          inlineParser,
          lineStart,
          source.length,
          source.length,
        ),
      );
    } else {
      // A trailing line feed creates a real empty editing line. The empty
      // document follows the same rule and exposes a caret target at 0.
      lines.add(
        _parseLine(source, inlineParser, lineStart, lineStart, lineStart),
      );
    }

    return MarkdownSyntaxTree._(source: source, lines: lines);
  }

  MarkdownLineNode _parseLine(
    String source,
    _InlineParser inlineParser,
    int start,
    int logicalEnd,
    int fullEnd,
  ) {
    final fullRange = SourceRange(start, fullEnd);
    final endingRange = SourceRange(logicalEnd, fullEnd);
    if (start == logicalEnd) {
      final empty = SourceRange(start, start);
      return MarkdownLineNode(
        kind: MarkdownLineKind.blank,
        fullRange: fullRange,
        contentRange: empty,
        prefixRange: empty,
        lineEndingRange: endingRange,
        delimiterRanges: const [],
        inlines: const [],
      );
    }

    var cursor = start;
    while (cursor < logicalEnd &&
        cursor - start < 3 &&
        source.codeUnitAt(cursor) == _space) {
      cursor++;
    }

    final heading = _headingAt(source, start, cursor, logicalEnd);
    if (heading != null) {
      final inlines = inlineParser.parse(
        heading.contentRange.start,
        heading.contentRange.end,
      );
      return MarkdownLineNode(
        kind: MarkdownLineKind.atxHeading,
        fullRange: fullRange,
        contentRange: heading.contentRange,
        prefixRange: SourceRange(start, heading.contentRange.start),
        lineEndingRange: endingRange,
        delimiterRanges: heading.delimiters,
        inlines: inlines,
        headingLevel: heading.level,
        marker: source.substring(heading.markerStart, heading.markerEnd),
      );
    }

    if (cursor < logicalEnd && source.codeUnitAt(cursor) == _greaterThan) {
      final markerRange = SourceRange(cursor, cursor + 1);
      var contentStart = cursor + 1;
      if (contentStart < logicalEnd &&
          _isHorizontalWhitespace(source.codeUnitAt(contentStart))) {
        contentStart++;
      }
      final contentRange = SourceRange(contentStart, logicalEnd);
      return MarkdownLineNode(
        kind: MarkdownLineKind.blockquote,
        fullRange: fullRange,
        contentRange: contentRange,
        prefixRange: SourceRange(start, contentStart),
        lineEndingRange: endingRange,
        delimiterRanges: [markerRange],
        inlines: inlineParser.parse(contentStart, logicalEnd),
        marker: '>',
      );
    }

    final list = _listAt(source, cursor, logicalEnd);
    if (list != null) {
      final contentRange = SourceRange(list.contentStart, logicalEnd);
      return MarkdownLineNode(
        kind: list.taskMarkerRange == null
            ? list.ordered
                  ? MarkdownLineKind.orderedListItem
                  : MarkdownLineKind.unorderedListItem
            : MarkdownLineKind.taskListItem,
        fullRange: fullRange,
        contentRange: contentRange,
        prefixRange: SourceRange(start, list.contentStart),
        lineEndingRange: endingRange,
        delimiterRanges: [list.markerRange, ?list.taskMarkerRange],
        inlines: inlineParser.parse(list.contentStart, logicalEnd),
        marker: source.substring(list.markerRange.start, list.markerRange.end),
        ordinal: list.ordinal,
        taskChecked: list.taskChecked,
        taskMarkerRange: list.taskMarkerRange,
      );
    }

    final contentRange = SourceRange(start, logicalEnd);
    return MarkdownLineNode(
      kind: MarkdownLineKind.paragraph,
      fullRange: fullRange,
      contentRange: contentRange,
      prefixRange: SourceRange(start, start),
      lineEndingRange: endingRange,
      delimiterRanges: const [],
      inlines: inlineParser.parse(start, logicalEnd),
    );
  }

  _HeadingMatch? _headingAt(
    String source,
    int lineStart,
    int markerStart,
    int end,
  ) {
    if (markerStart >= end || source.codeUnitAt(markerStart) != _hash) {
      return null;
    }
    var markerEnd = markerStart;
    while (markerEnd < end &&
        markerEnd - markerStart < 6 &&
        source.codeUnitAt(markerEnd) == _hash) {
      markerEnd++;
    }
    if (markerEnd < end && source.codeUnitAt(markerEnd) == _hash) return null;
    if (markerEnd < end &&
        !_isHorizontalWhitespace(source.codeUnitAt(markerEnd))) {
      return null;
    }

    var contentStart = markerEnd;
    while (contentStart < end &&
        _isHorizontalWhitespace(source.codeUnitAt(contentStart))) {
      contentStart++;
    }

    var contentEnd = end;
    var trailingWhitespaceStart = end;
    while (trailingWhitespaceStart > contentStart &&
        _isHorizontalWhitespace(
          source.codeUnitAt(trailingWhitespaceStart - 1),
        )) {
      trailingWhitespaceStart--;
    }
    var closingStart = trailingWhitespaceStart;
    while (closingStart > contentStart &&
        source.codeUnitAt(closingStart - 1) == _hash) {
      closingStart--;
    }

    SourceRange? closingRange;
    if (closingStart < trailingWhitespaceStart &&
        closingStart > contentStart &&
        _isHorizontalWhitespace(source.codeUnitAt(closingStart - 1))) {
      closingRange = SourceRange(closingStart, trailingWhitespaceStart);
      contentEnd = closingStart;
      while (contentEnd > contentStart &&
          _isHorizontalWhitespace(source.codeUnitAt(contentEnd - 1))) {
        contentEnd--;
      }
    }

    return _HeadingMatch(
      level: markerEnd - markerStart,
      markerStart: markerStart,
      markerEnd: markerEnd,
      contentRange: SourceRange(contentStart, contentEnd),
      delimiters: [SourceRange(markerStart, markerEnd), ?closingRange],
    );
  }

  _ListMatch? _listAt(String source, int start, int end) {
    if (start >= end) return null;
    var cursor = start;
    var ordered = false;
    int? ordinal;
    late SourceRange markerRange;

    final first = source.codeUnitAt(cursor);
    if (first == _dash || first == _plus || first == _asterisk) {
      markerRange = SourceRange(cursor, cursor + 1);
      cursor++;
    } else if (_isDigit(first)) {
      final digitsStart = cursor;
      while (cursor < end &&
          cursor - digitsStart < 9 &&
          _isDigit(source.codeUnitAt(cursor))) {
        cursor++;
      }
      if (cursor == digitsStart ||
          cursor >= end ||
          (source.codeUnitAt(cursor) != _dot &&
              source.codeUnitAt(cursor) != _rightParen)) {
        return null;
      }
      // Ten or more digits are not a CommonMark ordered-list marker.
      if (cursor - digitsStart == 9 &&
          cursor + 1 < end &&
          _isDigit(source.codeUnitAt(cursor))) {
        return null;
      }
      cursor++;
      markerRange = SourceRange(digitsStart, cursor);
      ordinal = int.tryParse(source.substring(digitsStart, cursor - 1));
      ordered = true;
    } else {
      return null;
    }

    if (cursor >= end || !_isHorizontalWhitespace(source.codeUnitAt(cursor))) {
      return null;
    }
    while (cursor < end && _isHorizontalWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }

    SourceRange? taskMarkerRange;
    bool? taskChecked;
    if (cursor + 2 < end &&
        source.codeUnitAt(cursor) == _leftBracket &&
        source.codeUnitAt(cursor + 2) == _rightBracket) {
      final state = source.codeUnitAt(cursor + 1);
      final validState =
          state == _space || state == _lowerX || state == _upperX;
      final followedByWhitespace =
          cursor + 3 == end ||
          _isHorizontalWhitespace(source.codeUnitAt(cursor + 3));
      if (validState && followedByWhitespace) {
        taskMarkerRange = SourceRange(cursor, cursor + 3);
        taskChecked = state == _lowerX || state == _upperX;
        cursor += 3;
        while (cursor < end &&
            _isHorizontalWhitespace(source.codeUnitAt(cursor))) {
          cursor++;
        }
      }
    }

    return _ListMatch(
      ordered: ordered,
      markerRange: markerRange,
      contentStart: cursor,
      ordinal: ordinal,
      taskMarkerRange: taskMarkerRange,
      taskChecked: taskChecked,
    );
  }
}

class _InlineParser {
  const _InlineParser(this.source);

  final String source;

  List<MarkdownInlineNode> parse(int start, int end, {bool allowLinks = true}) {
    final result = <MarkdownInlineNode>[];
    var textStart = start;
    var cursor = start;

    void flushText(int textEnd) {
      if (textEnd <= textStart) return;
      final range = SourceRange(textStart, textEnd);
      result.add(
        MarkdownInlineNode(
          kind: MarkdownInlineKind.text,
          fullRange: range,
          contentRange: range,
          delimiterRanges: const [],
        ),
      );
    }

    while (cursor < end) {
      if (_isEscaped(source, cursor)) {
        cursor = _skipSameCharacterRun(source, cursor, end);
        continue;
      }

      MarkdownInlineNode? node;
      final codeUnit = source.codeUnitAt(cursor);
      if (codeUnit == _backtick) {
        node = _codeAt(cursor, end);
      } else if (codeUnit == _bang &&
          cursor + 1 < end &&
          source.codeUnitAt(cursor + 1) == _leftBracket) {
        node = _imageAt(cursor, end);
      } else if (codeUnit == _leftBracket) {
        if (cursor + 1 < end && source.codeUnitAt(cursor + 1) == _leftBracket) {
          node = _wikiAt(cursor, end);
        }
        node ??= allowLinks ? _linkAt(cursor, end) : null;
      } else if (allowLinks &&
          (source.startsWith('https://', cursor) ||
              source.startsWith('http://', cursor)) &&
          (cursor == start || RegExp(r'[\s(<]').hasMatch(source[cursor - 1]))) {
        final match = RegExp(r'https?://[^\s<>]+')
            .matchAsPrefix(source, cursor);
        if (match != null) {
          var linkEnd = match.end < end ? match.end : end;
          while (linkEnd > cursor && '.,;:!?)'.contains(source[linkEnd - 1])) {
            linkEnd--;
          }
          if (linkEnd > cursor) {
            final range = SourceRange(cursor, linkEnd);
            node = MarkdownInlineNode(
              kind: MarkdownInlineKind.link,
              fullRange: range,
              contentRange: range,
              destinationRange: range,
              delimiterRanges: const [],
              children: const [],
            );
          }
        }
      } else if (codeUnit == _asterisk || codeUnit == _underscore) {
        final runLength = _sameCharacterRunLength(source, cursor, end);
        if (runLength == 1) {
          node = _pairedAt(
            cursor,
            end,
            String.fromCharCode(codeUnit),
            MarkdownInlineKind.italic,
          );
        } else if (runLength == 2) {
          node = _pairedAt(
            cursor,
            end,
            String.fromCharCodes([codeUnit, codeUnit]),
            MarkdownInlineKind.bold,
          );
        }
      } else if (codeUnit == _tilde &&
          _sameCharacterRunLength(source, cursor, end) == 2) {
        node = _pairedAt(cursor, end, '~~', MarkdownInlineKind.strikethrough);
      } else if (codeUnit == _equals &&
          _sameCharacterRunLength(source, cursor, end) == 2) {
        node = _pairedAt(cursor, end, '==', MarkdownInlineKind.highlight);
      } else if (codeUnit == _lessThan) {
        node = _fontSizeAt(cursor, end);
      }

      if (node == null) {
        if (_isRunDelimiter(codeUnit)) {
          cursor = _skipSameCharacterRun(source, cursor, end);
        } else {
          cursor++;
        }
        continue;
      }

      flushText(cursor);
      result.add(node);
      cursor = node.fullRange.end;
      textStart = cursor;
    }

    flushText(end);
    return List.unmodifiable(result);
  }

  MarkdownInlineNode? _pairedAt(
    int start,
    int end,
    String delimiter,
    MarkdownInlineKind kind,
  ) {
    final delimiterLength = delimiter.length;
    if (!_canOpen(start, delimiterLength, end, delimiter.codeUnitAt(0))) {
      return null;
    }
    final close = _findClosingDelimiter(
      start + delimiterLength,
      end,
      delimiter,
    );
    if (close == null || close == start + delimiterLength) return null;

    final contentRange = SourceRange(start + delimiterLength, close);
    return MarkdownInlineNode(
      kind: kind,
      fullRange: SourceRange(start, close + delimiterLength),
      contentRange: contentRange,
      delimiterRanges: [
        SourceRange(start, start + delimiterLength),
        SourceRange(close, close + delimiterLength),
      ],
      children: parse(contentRange.start, contentRange.end),
    );
  }

  /// Recognizes `<span style="font-size:Npx">…</span>` with 8 ≤ N ≤ 72.
  ///
  /// Only this exact inline HTML form is treated as formatting; any other HTML
  /// stays literal text. Nested runs are balanced by depth, so re-formatting a
  /// part of an existing run still renders both sizes correctly. The closing
  /// tag must be on the same physical line; the application wraps multi-line
  /// selections line by line for that reason.
  MarkdownInlineNode? _fontSizeAt(int start, int end) {
    final open = _fontSizeOpenTag.matchAsPrefix(source, start);
    if (open == null || open.end >= end) return null;
    final size = double.tryParse(open.group(1)!);
    if (size == null || size < 8 || size > 72) return null;
    var depth = 1;
    var cursor = open.end;
    var close = -1;
    while (cursor < end) {
      final openIndex = source.indexOf(_fontSizeOpenPrefix, cursor);
      final closeIndex = source.indexOf(_fontSpanClose, cursor);
      if (closeIndex < 0 || closeIndex + _fontSpanClose.length > end) {
        return null;
      }
      if (openIndex >= 0 && openIndex < closeIndex) {
        depth++;
        cursor = openIndex + _fontSizeOpenPrefix.length;
        continue;
      }
      depth--;
      if (depth == 0) {
        close = closeIndex;
        break;
      }
      cursor = closeIndex + _fontSpanClose.length;
    }
    if (close < 0 || close == open.end) return null;
    final contentRange = SourceRange(open.end, close);
    return MarkdownInlineNode(
      kind: MarkdownInlineKind.fontSize,
      fullRange: SourceRange(start, close + _fontSpanClose.length),
      contentRange: contentRange,
      delimiterRanges: [
        SourceRange(start, open.end),
        SourceRange(close, close + _fontSpanClose.length),
      ],
      children: parse(contentRange.start, contentRange.end),
      fontSize: size,
    );
  }

  int? _findClosingDelimiter(int start, int end, String delimiter) {
    final character = delimiter.codeUnitAt(0);
    final requiredLength = delimiter.length;
    var cursor = start;
    while (cursor < end) {
      if (source.codeUnitAt(cursor) != character) {
        cursor++;
        continue;
      }
      final runLength = _sameCharacterRunLength(source, cursor, end);
      if (!_isEscaped(source, cursor) &&
          runLength == requiredLength &&
          _canClose(cursor, requiredLength, end, character)) {
        return cursor;
      }
      cursor += runLength;
    }
    return null;
  }

  bool _canOpen(int start, int length, int regionEnd, int character) {
    final after = start + length;
    if (after >= regionEnd || _isWhitespace(source.codeUnitAt(after))) {
      return false;
    }
    if (character != _underscore || start == 0) return true;
    return !(_isWord(source.codeUnitAt(start - 1)) &&
        _isWord(source.codeUnitAt(after)));
  }

  bool _canClose(int start, int length, int regionEnd, int character) {
    if (start == 0 || _isWhitespace(source.codeUnitAt(start - 1))) return false;
    final after = start + length;
    if (character != _underscore || after >= regionEnd) return true;
    return !(_isWord(source.codeUnitAt(start - 1)) &&
        _isWord(source.codeUnitAt(after)));
  }

  MarkdownInlineNode? _codeAt(int start, int end) {
    final delimiterLength = _sameCharacterRunLength(source, start, end);
    var cursor = start + delimiterLength;
    while (cursor < end) {
      if (source.codeUnitAt(cursor) != _backtick) {
        cursor++;
        continue;
      }
      final runLength = _sameCharacterRunLength(source, cursor, end);
      if (!_isEscaped(source, cursor) && runLength == delimiterLength) {
        final contentRange = SourceRange(start + delimiterLength, cursor);
        if (contentRange.isCollapsed) return null;
        return MarkdownInlineNode(
          kind: MarkdownInlineKind.codeSpan,
          fullRange: SourceRange(start, cursor + delimiterLength),
          contentRange: contentRange,
          delimiterRanges: [
            SourceRange(start, start + delimiterLength),
            SourceRange(cursor, cursor + delimiterLength),
          ],
        );
      }
      cursor += runLength;
    }
    return null;
  }

  MarkdownInlineNode? _wikiAt(int start, int end) {
    var cursor = start + 2;
    int? aliasSeparator;
    while (cursor + 1 < end) {
      if (_isEscaped(source, cursor)) {
        cursor++;
        continue;
      }
      final codeUnit = source.codeUnitAt(cursor);
      if (codeUnit == _lineFeed || codeUnit == _carriageReturn) return null;
      if (codeUnit == _pipe && aliasSeparator == null) {
        aliasSeparator = cursor;
      }
      if (codeUnit == _rightBracket &&
          source.codeUnitAt(cursor + 1) == _rightBracket) {
        final targetEnd = aliasSeparator ?? cursor;
        if (targetEnd == start + 2) return null;
        final targetRange = SourceRange(start + 2, targetEnd);
        final aliasRange = aliasSeparator == null
            ? null
            : SourceRange(aliasSeparator + 1, cursor);
        if (aliasRange != null && aliasRange.isCollapsed) return null;
        final contentRange = aliasRange ?? targetRange;
        return MarkdownInlineNode(
          kind: MarkdownInlineKind.wikiLink,
          fullRange: SourceRange(start, cursor + 2),
          contentRange: contentRange,
          delimiterRanges: [
            SourceRange(start, start + 2),
            if (aliasSeparator != null)
              SourceRange(aliasSeparator, aliasSeparator + 1),
            SourceRange(cursor, cursor + 2),
          ],
          children: parse(
            contentRange.start,
            contentRange.end,
            allowLinks: false,
          ),
          targetRange: targetRange,
          aliasRange: aliasRange,
        );
      }
      cursor++;
    }
    return null;
  }

  MarkdownInlineNode? _linkAt(int start, int end) {
    final labelEnd = _findLabelEnd(start, end);
    if (labelEnd == null || labelEnd == start + 1 || labelEnd + 1 >= end) {
      return null;
    }
    if (source.codeUnitAt(labelEnd + 1) != _leftParen) return null;

    final tail = _parseLinkTail(labelEnd + 1, end);
    if (tail == null) return null;
    final labelRange = SourceRange(start + 1, labelEnd);
    return MarkdownInlineNode(
      kind: MarkdownInlineKind.link,
      fullRange: SourceRange(start, tail.fullEnd),
      contentRange: labelRange,
      delimiterRanges: [
        SourceRange(start, start + 1),
        SourceRange(labelEnd, labelEnd + 2),
        ...tail.extraDelimiters,
        SourceRange(tail.fullEnd - 1, tail.fullEnd),
      ],
      children: parse(labelRange.start, labelRange.end, allowLinks: false),
      destinationRange: tail.destinationRange,
      titleRange: tail.titleRange,
    );
  }

  MarkdownInlineNode? _imageAt(int start, int end) {
    // [start] points at the `!`; the next code unit is the opening `[`.
    final labelStart = start + 1;
    final labelEnd = _findLabelEnd(labelStart, end);
    if (labelEnd == null || labelEnd + 1 >= end) {
      return null;
    }
    if (source.codeUnitAt(labelEnd + 1) != _leftParen) return null;

    final tail = _parseLinkTail(labelEnd + 1, end);
    if (tail == null) return null;
    return MarkdownInlineNode(
      kind: MarkdownInlineKind.image,
      fullRange: SourceRange(start, tail.fullEnd),
      contentRange: SourceRange(start + 2, labelEnd),
      delimiterRanges: [
        SourceRange(start, start + 2),
        SourceRange(labelEnd, labelEnd + 2),
        ...tail.extraDelimiters,
        SourceRange(tail.fullEnd - 1, tail.fullEnd),
      ],
      destinationRange: tail.destinationRange,
      titleRange: tail.titleRange,
    );
  }

  int? _findLabelEnd(int start, int end) {
    var depth = 1;
    var cursor = start + 1;
    while (cursor < end) {
      if (_isEscaped(source, cursor)) {
        cursor++;
        continue;
      }
      final codeUnit = source.codeUnitAt(cursor);
      if (codeUnit == _lineFeed || codeUnit == _carriageReturn) return null;
      if (codeUnit == _backtick) {
        final code = _codeAt(cursor, end);
        if (code != null) {
          cursor = code.fullRange.end;
          continue;
        }
      }
      if (codeUnit == _leftBracket) {
        depth++;
      } else if (codeUnit == _rightBracket) {
        depth--;
        if (depth == 0) return cursor;
      }
      cursor++;
    }
    return null;
  }

  _LinkTail? _parseLinkTail(int openParen, int end) {
    var cursor = openParen + 1;
    while (cursor < end && _isHorizontalWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }

    final extraDelimiters = <SourceRange>[];
    late SourceRange destinationRange;
    if (cursor < end && source.codeUnitAt(cursor) == _lessThan) {
      final angleStart = cursor;
      cursor++;
      final destinationStart = cursor;
      while (cursor < end) {
        final character = source.codeUnitAt(cursor);
        if (character == _lineFeed || character == _carriageReturn) return null;
        if (character == _backslash && cursor + 1 < end) {
          final next = source.codeUnitAt(cursor + 1);
          if (next == _lineFeed || next == _carriageReturn) return null;
          cursor += 2;
        } else {
          if (character == _greaterThan) break;
          cursor++;
        }
      }
      if (cursor >= end || source.codeUnitAt(cursor) != _greaterThan) {
        return null;
      }
      destinationRange = SourceRange(destinationStart, cursor);
      extraDelimiters.add(SourceRange(angleStart, angleStart + 1));
      extraDelimiters.add(SourceRange(cursor, cursor + 1));
      cursor++;
    } else {
      final destinationStart = cursor;
      var depth = 0;
      while (cursor < end) {
        if (_isEscaped(source, cursor)) {
          cursor += 2;
          continue;
        }
        final codeUnit = source.codeUnitAt(cursor);
        if (codeUnit == _lineFeed || codeUnit == _carriageReturn) return null;
        if (_isHorizontalWhitespace(codeUnit) && depth == 0) break;
        if (codeUnit == _leftParen) {
          depth++;
        } else if (codeUnit == _rightParen) {
          if (depth == 0) {
            destinationRange = SourceRange(destinationStart, cursor);
            return _LinkTail(
              fullEnd: cursor + 1,
              destinationRange: destinationRange,
              extraDelimiters: extraDelimiters,
            );
          }
          depth--;
        }
        cursor++;
      }
      if (depth != 0) return null;
      destinationRange = SourceRange(destinationStart, cursor);
    }

    final whitespaceStart = cursor;
    while (cursor < end && _isHorizontalWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor < end && source.codeUnitAt(cursor) == _rightParen) {
      return _LinkTail(
        fullEnd: cursor + 1,
        destinationRange: destinationRange,
        extraDelimiters: extraDelimiters,
      );
    }
    if (cursor == whitespaceStart || cursor >= end) return null;

    final titleOpening = source.codeUnitAt(cursor);
    final titleClosing = switch (titleOpening) {
      _doubleQuote => _doubleQuote,
      _singleQuote => _singleQuote,
      _leftParen => _rightParen,
      _ => null,
    };
    if (titleClosing == null) return null;
    final titleOpen = cursor;
    cursor++;
    final titleStart = cursor;
    while (cursor < end) {
      if (_isEscaped(source, cursor)) {
        cursor += 2;
        continue;
      }
      final codeUnit = source.codeUnitAt(cursor);
      if (codeUnit == _lineFeed || codeUnit == _carriageReturn) return null;
      if (codeUnit == titleClosing) break;
      cursor++;
    }
    if (cursor >= end || source.codeUnitAt(cursor) != titleClosing) return null;
    final titleRange = SourceRange(titleStart, cursor);
    extraDelimiters.add(SourceRange(titleOpen, titleOpen + 1));
    extraDelimiters.add(SourceRange(cursor, cursor + 1));
    cursor++;
    while (cursor < end && _isHorizontalWhitespace(source.codeUnitAt(cursor))) {
      cursor++;
    }
    if (cursor >= end || source.codeUnitAt(cursor) != _rightParen) return null;
    return _LinkTail(
      fullEnd: cursor + 1,
      destinationRange: destinationRange,
      titleRange: titleRange,
      extraDelimiters: extraDelimiters,
    );
  }
}

class _HeadingMatch {
  const _HeadingMatch({
    required this.level,
    required this.markerStart,
    required this.markerEnd,
    required this.contentRange,
    required this.delimiters,
  });

  final int level;
  final int markerStart;
  final int markerEnd;
  final SourceRange contentRange;
  final List<SourceRange> delimiters;
}

class _ListMatch {
  const _ListMatch({
    required this.ordered,
    required this.markerRange,
    required this.contentStart,
    this.ordinal,
    this.taskMarkerRange,
    this.taskChecked,
  });

  final bool ordered;
  final SourceRange markerRange;
  final int contentStart;
  final int? ordinal;
  final SourceRange? taskMarkerRange;
  final bool? taskChecked;
}

class _LinkTail {
  const _LinkTail({
    required this.fullEnd,
    required this.destinationRange,
    required this.extraDelimiters,
    this.titleRange,
  });

  final int fullEnd;
  final SourceRange destinationRange;
  final SourceRange? titleRange;
  final List<SourceRange> extraDelimiters;
}

const String _fontSizeOpenPrefix = '<span style="font-size:';
const String _fontSpanClose = '</span>';
final RegExp _fontSizeOpenTag = RegExp(
  '${RegExp.escape(_fontSizeOpenPrefix)}(\\d{1,2}(?:\\.\\d)?)px">',
);

bool _isEscaped(String source, int offset) {
  var slashCount = 0;
  for (
    var index = offset - 1;
    index >= 0 && source.codeUnitAt(index) == _backslash;
    index--
  ) {
    slashCount++;
  }
  return slashCount.isOdd;
}

int _sameCharacterRunLength(String source, int start, int end) {
  final character = source.codeUnitAt(start);
  var cursor = start + 1;
  while (cursor < end && source.codeUnitAt(cursor) == character) {
    cursor++;
  }
  return cursor - start;
}

int _skipSameCharacterRun(String source, int start, int end) =>
    start + _sameCharacterRunLength(source, start, end);

bool _isRunDelimiter(int codeUnit) =>
    codeUnit == _asterisk ||
    codeUnit == _underscore ||
    codeUnit == _tilde ||
    codeUnit == _equals ||
    codeUnit == _backtick;

bool _isHorizontalWhitespace(int codeUnit) =>
    codeUnit == _space || codeUnit == _tab;

bool _isWhitespace(int codeUnit) =>
    _isHorizontalWhitespace(codeUnit) ||
    codeUnit == _lineFeed ||
    codeUnit == _carriageReturn;

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

bool _isWord(int codeUnit) =>
    (codeUnit >= 0x30 && codeUnit <= 0x39) ||
    (codeUnit >= 0x41 && codeUnit <= 0x5a) ||
    (codeUnit >= 0x61 && codeUnit <= 0x7a) ||
    codeUnit == _underscore ||
    codeUnit >= 0x80;

const int _bang = 0x21;
const int _tab = 0x09;
const int _lineFeed = 0x0a;
const int _carriageReturn = 0x0d;
const int _space = 0x20;
const int _doubleQuote = 0x22;
const int _hash = 0x23;
const int _singleQuote = 0x27;
const int _leftParen = 0x28;
const int _rightParen = 0x29;
const int _asterisk = 0x2a;
const int _plus = 0x2b;
const int _dash = 0x2d;
const int _dot = 0x2e;
const int _lessThan = 0x3c;
const int _equals = 0x3d;
const int _greaterThan = 0x3e;
const int _upperX = 0x58;
const int _leftBracket = 0x5b;
const int _backslash = 0x5c;
const int _rightBracket = 0x5d;
const int _underscore = 0x5f;
const int _backtick = 0x60;
const int _lowerX = 0x78;
const int _pipe = 0x7c;
const int _tilde = 0x7e;
