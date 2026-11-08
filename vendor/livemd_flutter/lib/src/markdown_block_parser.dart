import 'markdown_block.dart';
import 'markdown_table.dart';

/// A lightweight, lossless block scanner used by the live preview layout.
class MarkdownBlockParser {
  /// Creates a stateless block scanner.
  const MarkdownBlockParser();

  static final RegExp _heading = RegExp(r'^ {0,3}#{1,6}(?:\s|$)');
  static final RegExp _blockquote = RegExp(r'^ {0,3}>');
  static final RegExp _callout = RegExp(r'^ {0,3}>\s*\[![^\]]+\]');
  static final RegExp _list = RegExp(
    r'^ {0,3}(?:(?:[-+*])|(?:\d{1,9}[.)]))\s+',
  );
  static final RegExp _fence = RegExp(r'^ {0,3}(`{3,}|~{3,})');
  static final RegExp _closingFence = RegExp(r'^ {0,3}(`+|~+)[ \t]*$');
  static final RegExp _thematicBreak = RegExp(
    r'^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$',
  );

  /// Splits [source] into ordered lossless blocks with UTF-16 source offsets.
  /// Empty input produces one empty blank block. Joining block sources restores
  /// the original string; unsupported constructs remain ordinary source.
  List<MarkdownBlock> parse(String source) {
    if (source.isEmpty) {
      return const [
        MarkdownBlock(
          type: MarkdownBlockType.blank,
          sourceStart: 0,
          sourceEnd: 0,
          source: '',
        ),
      ];
    }

    final lines = _linesOf(source);
    final blocks = <MarkdownBlock>[];
    var index = 0;

    while (index < lines.length) {
      final startLine = index;
      final first = lines[index].text;
      late MarkdownBlockType type;

      if (first.trim().isEmpty) {
        type = MarkdownBlockType.blank;
        while (index < lines.length && lines[index].text.trim().isEmpty) {
          index++;
        }
      } else if (_fence.hasMatch(first)) {
        type = MarkdownBlockType.codeFence;
        final marker = _fence.firstMatch(first)!.group(1)!;
        final markerCharacter = marker[0];
        final minimumLength = marker.length;
        index++;
        while (index < lines.length) {
          final candidate = lines[index].text;
          index++;
          if (_isClosingFence(candidate, markerCharacter, minimumLength)) break;
        }
      } else if (_heading.hasMatch(first)) {
        type = MarkdownBlockType.heading;
        index++;
      } else if (_thematicBreak.hasMatch(first)) {
        type = MarkdownBlockType.thematicBreak;
        index++;
      } else if (_blockquote.hasMatch(first)) {
        type = _callout.hasMatch(first)
            ? MarkdownBlockType.callout
            : MarkdownBlockType.blockquote;
        index++;
        while (index < lines.length &&
            _blockquote.hasMatch(lines[index].text)) {
          index++;
        }
      } else if (_list.hasMatch(first)) {
        type = MarkdownBlockType.list;
        index++;
        while (index < lines.length &&
            !_list.hasMatch(lines[index].text) &&
            _continuesListItem(lines[index].text)) {
          index++;
        }
      } else if (_tableEnd(lines, index) case final tableEnd?) {
        type = MarkdownBlockType.table;
        index = tableEnd;
      } else {
        type = MarkdownBlockType.paragraph;
        index++;
        while (index < lines.length &&
            lines[index].text.trim().isNotEmpty &&
            !_startsStandaloneBlockAt(lines, index)) {
          index++;
        }
      }

      final start = lines[startLine].start;
      final end = lines[index - 1].end;
      blocks.add(
        MarkdownBlock(
          type: type,
          sourceStart: start,
          sourceEnd: end,
          source: source.substring(start, end),
        ),
      );
    }

    return _detachTrailingLineBreaks(blocks, source);
  }

  List<MarkdownBlock> _detachTrailingLineBreaks(
    List<MarkdownBlock> blocks,
    String source,
  ) {
    final result = <MarkdownBlock>[];

    void addBlock(MarkdownBlock block) {
      if (block.source.isEmpty) return;
      if (result.isNotEmpty &&
          result.last.type == MarkdownBlockType.blank &&
          block.type == MarkdownBlockType.blank &&
          result.last.sourceEnd == block.sourceStart) {
        final previous = result.removeLast();
        result.add(
          MarkdownBlock(
            type: MarkdownBlockType.blank,
            sourceStart: previous.sourceStart,
            sourceEnd: block.sourceEnd,
            source: source.substring(previous.sourceStart, block.sourceEnd),
          ),
        );
        return;
      }
      result.add(block);
    }

    for (final block in blocks) {
      final hasLineFeed =
          block.type != MarkdownBlockType.blank && block.source.endsWith('\n');
      if (!hasLineFeed) {
        addBlock(block);
        continue;
      }
      final isCrLf = block.source.length >= 2 && block.source.endsWith('\r\n');
      final contentEnd = block.sourceEnd - (isCrLf ? 2 : 1);
      addBlock(
        MarkdownBlock(
          type: block.type,
          sourceStart: block.sourceStart,
          sourceEnd: contentEnd,
          source: source.substring(block.sourceStart, contentEnd),
        ),
      );
      addBlock(
        MarkdownBlock(
          type: MarkdownBlockType.blank,
          sourceStart: contentEnd,
          sourceEnd: block.sourceEnd,
          source: source.substring(contentEnd, block.sourceEnd),
        ),
      );
    }
    return result;
  }

  bool _startsStandaloneBlockAt(List<_SourceLine> lines, int index) {
    final line = lines[index].text;
    return _startsNonTableBlock(line) || _tableEnd(lines, index) != null;
  }

  bool _startsNonTableBlock(String line) =>
      _heading.hasMatch(line) ||
      _blockquote.hasMatch(line) ||
      _list.hasMatch(line) ||
      _fence.hasMatch(line) ||
      _thematicBreak.hasMatch(line);

  int? _tableEnd(List<_SourceLine> lines, int start) {
    if (start + 1 >= lines.length) return null;
    final header = MarkdownTableRow.parse(
      lines[start].text,
      0,
      lines[start].text.length,
    );
    final separator = MarkdownTableRow.parse(
      lines[start + 1].text,
      0,
      lines[start + 1].text.length,
    );
    if (header == null ||
        separator == null ||
        separator.cells.length != header.cells.length ||
        !separator.cells.every(
          (cell) => cell.isSeparator(lines[start + 1].text),
        )) {
      return null;
    }

    var end = start + 2;
    while (end < lines.length) {
      final line = lines[end].text;
      if (line.trim().isEmpty ||
          _startsNonTableBlock(line) ||
          MarkdownTableRow.parse(line, 0, line.length) == null) {
        break;
      }
      end++;
    }
    return end;
  }

  bool _isClosingFence(String line, String markerCharacter, int minimumLength) {
    final marker = _closingFence.firstMatch(line)?.group(1);
    return marker != null &&
        marker[0] == markerCharacter &&
        marker.length >= minimumLength;
  }

  bool _continuesListItem(String line) {
    if (line.trim().isEmpty) return false;
    return line.startsWith('  ') || line.startsWith('\t');
  }

  List<_SourceLine> _linesOf(String source) {
    final lines = <_SourceLine>[];
    var start = 0;
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) != 10) continue;
      final contentEnd = i > start && source.codeUnitAt(i - 1) == 13
          ? i - 1
          : i;
      lines.add(
        _SourceLine(
          start: start,
          end: i + 1,
          text: source.substring(start, contentEnd),
        ),
      );
      start = i + 1;
    }
    if (start < source.length) {
      lines.add(
        _SourceLine(
          start: start,
          end: source.length,
          text: source.substring(start),
        ),
      );
    }
    return lines;
  }
}

class _SourceLine {
  const _SourceLine({
    required this.start,
    required this.end,
    required this.text,
  });

  final int start;
  final int end;
  final String text;
}
