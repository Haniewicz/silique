import 'markdown_block.dart';

/// A parsed, source-positioned Markdown table block.
///
/// Offsets use Dart UTF-16 string coordinates so the same rows and cells can
/// drive rendering, hit testing, and [TextEditingValue]-based commands without
/// translating between coordinate systems.
class MarkdownTableSource {
  const MarkdownTableSource({
    required this.block,
    required this.rows,
    required this.lineEnding,
  });

  static MarkdownTableSource? fromBlock(String document, MarkdownBlock block) {
    if (block.type != MarkdownBlockType.table) return null;
    final rows = <MarkdownTableRow>[];
    var lineStart = block.sourceStart;
    while (lineStart <= block.sourceEnd) {
      final newline = document.indexOf('\n', lineStart);
      final physicalEnd = newline < 0 || newline > block.sourceEnd
          ? block.sourceEnd
          : newline;
      var contentEnd = physicalEnd;
      if (contentEnd > lineStart &&
          document.codeUnitAt(contentEnd - 1) == 0x0d) {
        contentEnd--;
      }
      final row = MarkdownTableRow.parse(document, lineStart, contentEnd);
      if (row == null) return null;
      rows.add(row);
      if (physicalEnd >= block.sourceEnd) break;
      lineStart = physicalEnd + 1;
    }
    if (rows.length < 2) return null;
    return MarkdownTableSource(
      block: block,
      rows: rows,
      lineEnding: block.source.contains('\r\n') ? '\r\n' : '\n',
    );
  }

  final MarkdownBlock block;
  final List<MarkdownTableRow> rows;
  final String lineEnding;

  int get columnCount => rows.first.cells.length;

  MarkdownTableLocation? locationAt(int offset) {
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      if (offset < row.start || offset > row.end || row.cells.isEmpty) continue;
      if (offset < row.cells.first.start) return null;
      for (var column = 0; column < row.cells.length; column++) {
        final cell = row.cells[column];
        if (offset <= cell.end) {
          return MarkdownTableLocation(
            rowIndex: rowIndex,
            column: column,
            cell: cell,
          );
        }
      }
      return MarkdownTableLocation(
        rowIndex: rowIndex,
        column: row.cells.length - 1,
        cell: row.cells.last,
      );
    }
    return null;
  }

  List<MarkdownTableLocation> get editableLocations {
    final result = <MarkdownTableLocation>[];
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      if (rowIndex == 1) continue;
      final row = rows[rowIndex];
      final cellCount = row.cells.length < columnCount
          ? row.cells.length
          : columnCount;
      for (var column = 0; column < cellCount; column++) {
        result.add(
          MarkdownTableLocation(
            rowIndex: rowIndex,
            column: column,
            cell: row.cells[column],
          ),
        );
      }
    }
    return result;
  }
}

/// One physical table row and its absolute source ranges.
class MarkdownTableRow {
  const MarkdownTableRow({
    required this.start,
    required this.end,
    required this.indent,
    required this.cells,
  });

  static MarkdownTableRow? parse(String document, int start, int end) {
    var contentStart = start;
    while (contentStart < end && document.codeUnitAt(contentStart) == 0x20) {
      contentStart++;
    }
    if (contentStart - start > 3 ||
        (contentStart < end && document.codeUnitAt(contentStart) == 0x09)) {
      return null;
    }
    final indent = document.substring(start, contentStart);
    var contentEnd = end;
    while (contentEnd > contentStart &&
        (document.codeUnitAt(contentEnd - 1) == 0x20 ||
            document.codeUnitAt(contentEnd - 1) == 0x09)) {
      contentEnd--;
    }
    if (contentStart >= contentEnd) return null;

    final pipes = <int>[];
    for (var offset = contentStart; offset < contentEnd; offset++) {
      if (document.codeUnitAt(offset) == 0x7c &&
          !_isEscapedPipe(document, offset, start)) {
        pipes.add(offset);
      }
    }
    if (pipes.isEmpty) return null;

    final leadingPipe = pipes.first == contentStart;
    final trailingPipe = pipes.last == contentEnd - 1;
    final firstCellStart = leadingPipe ? contentStart + 1 : contentStart;
    final lastCellEnd = trailingPipe ? contentEnd - 1 : contentEnd;
    if (firstCellStart > lastCellEnd) return null;
    final cells = <MarkdownTableCell>[];
    var cursor = firstCellStart;
    for (final pipe in pipes) {
      if (pipe < firstCellStart || pipe >= lastCellEnd) continue;
      cells.add(MarkdownTableCell.parse(document, cursor, pipe));
      cursor = pipe + 1;
    }
    cells.add(MarkdownTableCell.parse(document, cursor, lastCellEnd));
    return MarkdownTableRow(
      start: start,
      end: end,
      indent: indent,
      cells: cells,
    );
  }

  final int start;
  final int end;
  final String indent;
  final List<MarkdownTableCell> cells;
}

/// One table cell's raw and trimmed content ranges.
class MarkdownTableCell {
  const MarkdownTableCell({
    required this.start,
    required this.end,
    required this.contentStart,
    required this.contentEnd,
    required this.editingOffset,
  });

  static MarkdownTableCell parse(String document, int start, int end) {
    var contentStart = start;
    while (contentStart < end &&
        (document.codeUnitAt(contentStart) == 0x20 ||
            document.codeUnitAt(contentStart) == 0x09)) {
      contentStart++;
    }
    var contentEnd = end;
    while (contentEnd > contentStart &&
        (document.codeUnitAt(contentEnd - 1) == 0x20 ||
            document.codeUnitAt(contentEnd - 1) == 0x09)) {
      contentEnd--;
    }
    final editingOffset = contentStart == end && start < end
        ? start + 1
        : contentStart;
    return MarkdownTableCell(
      start: start,
      end: end,
      contentStart: contentStart,
      contentEnd: contentEnd,
      editingOffset: editingOffset,
    );
  }

  final int start;
  final int end;
  final int contentStart;
  final int contentEnd;
  final int editingOffset;

  String textOf(String document) =>
      document.substring(contentStart, contentEnd);

  bool isSeparator(String document) =>
      RegExp(r'^:?-{3,}:?$').hasMatch(textOf(document));
}

/// A row/column coordinate paired with its source-positioned cell.
class MarkdownTableLocation {
  const MarkdownTableLocation({
    required this.rowIndex,
    required this.column,
    required this.cell,
  });

  final int rowIndex;
  final int column;
  final MarkdownTableCell cell;
}

bool _isEscapedPipe(String source, int offset, int lineStart) {
  var slashCount = 0;
  for (
    var index = offset - 1;
    index >= lineStart && source.codeUnitAt(index) == 0x5c;
    index--
  ) {
    slashCount++;
  }
  return slashCount.isOdd;
}
