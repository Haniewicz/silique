import 'package:flutter/services.dart';

import 'markdown_block.dart';
import 'markdown_block_parser.dart';
import 'markdown_table.dart';

/// Structural editing operations used by a Markdown source editor.
enum MarkdownEditingCommand {
  /// Insert a new line, continuing the current Markdown container when one is
  /// present.
  enter,

  /// Insert a visual continuation line aligned with the current content, but
  /// without copying its Markdown marker.
  shiftEnter,

  /// Remove one structural level when the caret is immediately after a line
  /// marker. At other collapsed caret positions this command is not handled.
  backspace,

  /// Indent list/task lines, or add one nested blockquote marker.
  tab,

  /// Outdent list/task lines, or remove one nested blockquote marker.
  shiftTab,

  /// Insert an empty body row immediately above the current table row.
  tableInsertRowAbove,

  /// Insert an empty body row immediately below the current table row.
  tableInsertRowBelow,

  /// Delete the current table body row.
  tableDeleteRow,

  /// Insert an empty table column immediately left of the current column.
  tableInsertColumnLeft,

  /// Insert an empty table column immediately right of the current column.
  tableInsertColumnRight,

  /// Delete the current table column while at least one column remains.
  tableDeleteColumn,
}

/// Applies an Obsidian-style structural Markdown editing [command].
///
/// Flutter's text offsets are UTF-16 code-unit offsets. This function keeps all
/// calculations in Dart string offsets, so the returned selection uses the
/// same coordinate system as [TextEditingValue].
///
/// With a usable selection, Enter and Shift+Enter return a value.
/// Backspace, Tab, and Shift+Tab
/// return `null` when they should fall through to the platform's ordinary
/// behavior. Backspace with a non-collapsed selection deletes that selection;
/// Tab and Shift+Tab preserve and transform multi-line selections.
///
/// [indentationWidth] is only a fallback for an isolated nested item. When a
/// preceding, shallower list item is available, its indentation is used as the
/// parent level instead.
///
/// This function does not mutate a controller. Apply a non-null result with
/// `controller.setValue(result)` to record it in document history. An invalid
/// selection or inapplicable table-only operation returns null. Table commands
/// target the cell containing the collapsed caret; the separator row is not
/// an editable body row.
TextEditingValue? applyMarkdownEditingCommand(
  TextEditingValue value,
  MarkdownEditingCommand command, {
  int indentationWidth = 2,
}) {
  assert(indentationWidth > 0);
  if (!_hasUsableSelection(value)) return null;

  final table = value.selection.isCollapsed
      ? _TableContext.maybeAt(value.text, value.selection.extentOffset)
      : null;
  if (table != null) {
    final tableResult = _applyTableCommand(value, command, table);
    if (tableResult != null) return tableResult;
  }
  if (_isTableOnlyCommand(command)) return null;

  if (command == MarkdownEditingCommand.tab ||
      command == MarkdownEditingCommand.shiftTab) {
    return _applyIndentationCommand(
      value,
      outdent: command == MarkdownEditingCommand.shiftTab,
      indentationWidth: indentationWidth,
    );
  }

  if (command == MarkdownEditingCommand.backspace &&
      !value.selection.isCollapsed) {
    return _replaceSelection(value, '');
  }

  final prepared = value.selection.isCollapsed
      ? value
      : _replaceSelection(value, '');
  final caret = prepared.selection.extentOffset;
  final line = _lineAt(prepared.text, caret);
  final markup = _LineMarkup.parse(line.text);

  return switch (command) {
    MarkdownEditingCommand.enter => _applyEnter(
      prepared,
      line,
      markup,
      indentationWidth: indentationWidth,
    ),
    MarkdownEditingCommand.shiftEnter => _applyShiftEnter(
      prepared,
      line,
      markup,
    ),
    MarkdownEditingCommand.backspace => _applyStructuralBackspace(
      prepared,
      line,
      markup,
      indentationWidth: indentationWidth,
    ),
    MarkdownEditingCommand.tab || MarkdownEditingCommand.shiftTab =>
      throw StateError('Indentation commands are handled before this switch.'),
    MarkdownEditingCommand.tableInsertRowAbove ||
    MarkdownEditingCommand.tableInsertRowBelow ||
    MarkdownEditingCommand.tableDeleteRow ||
    MarkdownEditingCommand.tableInsertColumnLeft ||
    MarkdownEditingCommand.tableInsertColumnRight ||
    MarkdownEditingCommand.tableDeleteColumn => throw StateError(
      'Table commands are handled before this switch.',
    ),
  };
}

/// Ensures that a rendered table cell has a concrete source range.
///
/// Ragged body rows can omit trailing cells that still exist visually because
/// the header defines the table width. Pointer editing materializes only the
/// requested row and returns a selection inside the new cell.
/// [tableStart] is the table's document-global UTF-16 start offset. [rowIndex]
/// counts source rows from zero (header 0, separator 1, first body row 2), and
/// [column] is zero-based. Invalid or separator-row targets return null.
/// Apply a non-null result through your controller; this function is pure.
TextEditingValue? materializeMarkdownTableCell(
  TextEditingValue value, {
  required int tableStart,
  required int rowIndex,
  required int column,
}) {
  if (!_hasUsableSelection(value) || rowIndex == 1 || column < 0) return null;
  MarkdownBlock? block;
  for (final candidate in const MarkdownBlockParser().parse(value.text)) {
    if (candidate.type == MarkdownBlockType.table &&
        candidate.sourceStart == tableStart) {
      block = candidate;
      break;
    }
  }
  if (block == null) return null;
  final table = MarkdownTableSource.fromBlock(value.text, block);
  if (table == null ||
      rowIndex < 0 ||
      rowIndex >= table.rows.length ||
      column >= table.columnCount) {
    return null;
  }
  final row = table.rows[rowIndex];
  if (column < row.cells.length) {
    return value.copyWith(
      selection: TextSelection.collapsed(
        offset: row.cells[column].editingOffset,
      ),
      composing: TextRange.empty,
    );
  }
  if (rowIndex < 2 || row.cells.isEmpty) return null;
  final context = _TableContext(
    table: table,
    location: MarkdownTableLocation(
      rowIndex: rowIndex,
      column: row.cells.length - 1,
      cell: row.cells.last,
    ),
  );
  return _padTableRowAndSelect(value, context, rowIndex, column);
}

bool _isTableOnlyCommand(MarkdownEditingCommand command) =>
    command == MarkdownEditingCommand.tableInsertRowAbove ||
    command == MarkdownEditingCommand.tableInsertRowBelow ||
    command == MarkdownEditingCommand.tableDeleteRow ||
    command == MarkdownEditingCommand.tableInsertColumnLeft ||
    command == MarkdownEditingCommand.tableInsertColumnRight ||
    command == MarkdownEditingCommand.tableDeleteColumn;

TextEditingValue? _applyTableCommand(
  TextEditingValue value,
  MarkdownEditingCommand command,
  _TableContext table,
) {
  return switch (command) {
    MarkdownEditingCommand.tab => _moveTableCell(value, table, forward: true),
    MarkdownEditingCommand.shiftTab => _moveTableCell(
      value,
      table,
      forward: false,
    ),
    MarkdownEditingCommand.enter => _moveTableRow(value, table),
    MarkdownEditingCommand.tableInsertRowAbove => _insertTableRow(
      value,
      table,
      below: false,
    ),
    MarkdownEditingCommand.tableInsertRowBelow => _insertTableRow(
      value,
      table,
      below: true,
    ),
    MarkdownEditingCommand.tableDeleteRow => _deleteTableRow(value, table),
    MarkdownEditingCommand.tableInsertColumnLeft => _editTableColumn(
      value,
      table,
      insert: true,
      after: false,
    ),
    MarkdownEditingCommand.tableInsertColumnRight => _editTableColumn(
      value,
      table,
      insert: true,
      after: true,
    ),
    MarkdownEditingCommand.tableDeleteColumn => _editTableColumn(
      value,
      table,
      insert: false,
      after: false,
    ),
    _ => null,
  };
}

TextEditingValue _moveTableCell(
  TextEditingValue value,
  _TableContext table, {
  required bool forward,
}) {
  final editable = table.editableLocations;
  final current = table.location;
  final currentColumn = current.column.clamp(0, table.columnCount - 1);
  if (current.rowIndex == 1) {
    if (forward) {
      final bodyIndex = editable.indexWhere(
        (location) => location.rowIndex >= 2,
      );
      if (bodyIndex < 0) {
        return _appendTableRow(value, table, targetColumn: 0);
      }
      return _tableSelectionValue(value, editable[bodyIndex]);
    }
    return _tableSelectionValue(
      value,
      editable.lastWhere((location) => location.rowIndex == 0),
    );
  }

  if (current.rowIndex >= 2) {
    final row = table.rows[current.rowIndex];
    final adjacentColumn = currentColumn + (forward ? 1 : -1);
    if (forward &&
        adjacentColumn < table.columnCount &&
        adjacentColumn >= row.cells.length) {
      return _padTableRowAndSelect(
        value,
        table,
        current.rowIndex,
        adjacentColumn,
      );
    }
    if (!forward && currentColumn == 0 && current.rowIndex > 2) {
      final previousRowIndex = current.rowIndex - 1;
      if (table.rows[previousRowIndex].cells.length < table.columnCount) {
        return _padTableRowAndSelect(
          value,
          table,
          previousRowIndex,
          table.columnCount - 1,
        );
      }
    }
  }

  final index = editable.indexWhere(
    (location) =>
        location.rowIndex == current.rowIndex &&
        location.column == currentColumn,
  );

  final targetIndex = forward ? index + 1 : index - 1;
  if (targetIndex >= editable.length) {
    return _appendTableRow(value, table, targetColumn: 0);
  }
  if (targetIndex < 0) return _tableSelectionValue(value, editable.first);
  return _tableSelectionValue(value, editable[targetIndex]);
}

TextEditingValue _moveTableRow(TextEditingValue value, _TableContext table) {
  final current = table.location;
  final column = current.column.clamp(0, table.columnCount - 1);
  final nextRowIndex = current.rowIndex < 2 ? 2 : current.rowIndex + 1;
  if (nextRowIndex >= table.rows.length) {
    return _appendTableRow(value, table, targetColumn: column);
  }
  final row = table.rows[nextRowIndex];
  if (row.cells.length <= column) {
    return _padTableRowAndSelect(value, table, nextRowIndex, column);
  }
  return _tableSelectionValue(
    value,
    MarkdownTableLocation(
      rowIndex: nextRowIndex,
      column: column,
      cell: row.cells[column],
    ),
  );
}

TextEditingValue _tableSelectionValue(
  TextEditingValue value,
  MarkdownTableLocation location,
) {
  return value.copyWith(
    selection: TextSelection.collapsed(offset: location.cell.editingOffset),
    composing: TextRange.empty,
  );
}

TextEditingValue _appendTableRow(
  TextEditingValue value,
  _TableContext table, {
  required int targetColumn,
}) {
  final row = _emptyTableRow(
    table.columnCount,
    indent: table.rows.first.indent,
  );
  final insertion = '${table.lineEnding}$row';
  final rowStart = table.block.sourceEnd + table.lineEnding.length;
  final nextText = value.text.replaceRange(
    table.block.sourceEnd,
    table.block.sourceEnd,
    insertion,
  );
  return _selectReparsedTableCell(
    value,
    nextText,
    tableStart: table.block.sourceStart,
    rowIndex: table.rows.length,
    column: targetColumn,
    fallback: rowStart + _canonicalCellOffset(targetColumn),
  );
}

TextEditingValue _padTableRowAndSelect(
  TextEditingValue value,
  _TableContext table,
  int rowIndex,
  int column,
) {
  final row = table.rows[rowIndex];
  final contents = row.cells
      .map((cell) => value.text.substring(cell.start, cell.end).trim())
      .toList();
  while (contents.length <= column) {
    contents.add('');
  }
  final replacement = '${row.indent}| ${contents.join(' | ')} |';
  final nextText = value.text.replaceRange(row.start, row.end, replacement);
  return _selectReparsedTableCell(
    value,
    nextText,
    tableStart: table.block.sourceStart,
    rowIndex: rowIndex,
    column: column,
    fallback: row.start,
  );
}

TextEditingValue? _insertTableRow(
  TextEditingValue value,
  _TableContext table, {
  required bool below,
}) {
  final current = table.location;
  final insertionRowIndex = current.rowIndex < 2
      ? 2
      : current.rowIndex + (below ? 1 : 0);
  final row = _emptyTableRow(
    table.columnCount,
    indent: table.rows.first.indent,
  );
  late int insertAt;
  late String insertion;
  if (insertionRowIndex < table.rows.length) {
    insertAt = table.rows[insertionRowIndex].start;
    insertion = '$row${table.lineEnding}';
  } else {
    insertAt = table.block.sourceEnd;
    insertion = '${table.lineEnding}$row';
  }
  final nextText = value.text.replaceRange(insertAt, insertAt, insertion);
  return _selectReparsedTableCell(
    value,
    nextText,
    tableStart: table.block.sourceStart,
    rowIndex: insertionRowIndex,
    column: current.column.clamp(0, table.columnCount - 1),
    fallback: insertAt,
  );
}

TextEditingValue? _deleteTableRow(TextEditingValue value, _TableContext table) {
  final rowIndex = table.location.rowIndex;
  if (rowIndex < 2) return null;
  final row = table.rows[rowIndex];
  late int start;
  late int end;
  late int targetRowIndex;
  if (rowIndex + 1 < table.rows.length) {
    start = row.start;
    end = table.rows[rowIndex + 1].start;
    targetRowIndex = rowIndex;
  } else {
    start = table.rows[rowIndex - 1].end;
    end = row.end;
    targetRowIndex = rowIndex - 1 == 1 ? 0 : rowIndex - 1;
  }
  final nextText = value.text.replaceRange(start, end, '');
  return _selectReparsedTableCell(
    value,
    nextText,
    tableStart: table.block.sourceStart,
    rowIndex: targetRowIndex,
    column: table.location.column.clamp(0, table.columnCount - 1),
    fallback: start,
  );
}

TextEditingValue? _editTableColumn(
  TextEditingValue value,
  _TableContext table, {
  required bool insert,
  required bool after,
}) {
  final oldColumnCount = table.columnCount;
  if (!insert && oldColumnCount <= 1) return null;
  final currentColumn = table.location.column.clamp(0, oldColumnCount - 1);
  final editColumn = insert && after ? currentColumn + 1 : currentColumn;
  final lines = <String>[];

  for (var rowIndex = 0; rowIndex < table.rows.length; rowIndex++) {
    final row = table.rows[rowIndex];
    final cells = row.cells
        .map((cell) => value.text.substring(cell.start, cell.end).trim())
        .toList();
    while (cells.length < oldColumnCount) {
      cells.add('');
    }
    if (insert) {
      cells.insert(editColumn, rowIndex == 1 ? '---' : '');
    } else if (editColumn < cells.length) {
      cells.removeAt(editColumn);
    }
    lines.add('${row.indent}| ${cells.join(' | ')} |');
  }

  final replacement = lines.join(table.lineEnding);
  final nextText = value.text.replaceRange(
    table.block.sourceStart,
    table.block.sourceEnd,
    replacement,
  );
  final targetColumn = insert
      ? editColumn
      : currentColumn.clamp(0, oldColumnCount - 2);
  return _selectReparsedTableCell(
    value,
    nextText,
    tableStart: table.block.sourceStart,
    rowIndex: table.location.rowIndex,
    column: targetColumn,
    fallback: table.block.sourceStart,
  );
}

TextEditingValue _selectReparsedTableCell(
  TextEditingValue original,
  String nextText, {
  required int tableStart,
  required int rowIndex,
  required int column,
  required int fallback,
}) {
  final context = _TableContext.maybeAt(
    nextText,
    _firstTableCellProbe(nextText, tableStart),
  );
  var caret = fallback.clamp(0, nextText.length);
  if (context != null && rowIndex < context.rows.length) {
    final row = context.rows[rowIndex];
    if (row.cells.isNotEmpty) {
      caret = row.cells[column.clamp(0, row.cells.length - 1)].editingOffset;
    }
  }
  return original.copyWith(
    text: nextText,
    selection: TextSelection.collapsed(offset: caret),
    composing: TextRange.empty,
  );
}

String _emptyTableRow(int columnCount, {String indent = ''}) =>
    '$indent| ${List<String>.filled(columnCount, '').join(' | ')} |';

int _firstTableCellProbe(String source, int tableStart) {
  final newline = source.indexOf('\n', tableStart);
  final lineEnd = newline < 0 ? source.length : newline;
  var offset = tableStart;
  while (offset < lineEnd &&
      (source.codeUnitAt(offset) == 0x20 ||
          source.codeUnitAt(offset) == 0x09)) {
    offset++;
  }
  if (offset < lineEnd && source.codeUnitAt(offset) == 0x7c) offset++;
  return offset;
}

int _canonicalCellOffset(int column) => 2 + column * 3;

TextEditingValue _applyEnter(
  TextEditingValue value,
  _SourceLine line,
  _LineMarkup? markup, {
  required int indentationWidth,
}) {
  final caretInLine = value.selection.extentOffset - line.start;
  if (markup == null || caretInLine < markup.contentStart) {
    return _insertAtCaret(value, '\n');
  }

  if (markup.kind != _MarkupKind.task &&
      markup.content(line.text).trim().isEmpty) {
    return _exitOrOutdentEmptyMarkup(
      value,
      line,
      markup,
      indentationWidth: indentationWidth,
    );
  }

  final result = _insertAtCaret(value, '\n${markup.nextLinePrefix}');
  if (markup.kind != _MarkupKind.orderedList) return result;
  return _renumberFollowingOrderedItems(
    result,
    insertedItemCaret: result.selection.extentOffset,
    indent: markup.indent,
    nextNumber: markup.orderedNumber! + 2,
    indentationWidth: indentationWidth,
  );
}

TextEditingValue _applyShiftEnter(
  TextEditingValue value,
  _SourceLine line,
  _LineMarkup? markup,
) {
  final caretInLine = value.selection.extentOffset - line.start;
  if (markup == null || caretInLine < markup.contentStart) {
    return _insertAtCaret(value, '\n');
  }
  return _insertAtCaret(value, '\n${markup.alignmentPrefix}');
}

TextEditingValue? _applyStructuralBackspace(
  TextEditingValue value,
  _SourceLine line,
  _LineMarkup? markup, {
  required int indentationWidth,
}) {
  if (markup == null) return null;
  final caretInLine = value.selection.extentOffset - line.start;
  if (caretInLine != markup.contentStart) return null;

  final replacement = _markupOneLevelShallower(
    value.text,
    line,
    markup,
    indentationWidth: indentationWidth,
  );
  return _replaceRange(
    value,
    line.start,
    line.start + markup.contentStart,
    replacement,
  );
}

TextEditingValue? _applyIndentationCommand(
  TextEditingValue value, {
  required bool outdent,
  required int indentationWidth,
}) {
  final firstLine = _lineAt(value.text, value.selection.start);
  final lastProbe = value.selection.isCollapsed
      ? value.selection.end
      : value.selection.end - 1;
  final lastLine = _lineAt(value.text, lastProbe);
  final replacements = <_TextReplacement>[];

  var lineStart = firstLine.start;
  while (lineStart <= lastLine.start) {
    final line = _lineAt(value.text, lineStart);
    final markup = _LineMarkup.parse(line.text);
    if (markup != null) {
      final replacement = outdent
          ? _outdentReplacement(
              value.text,
              line,
              markup,
              indentationWidth: indentationWidth,
            )
          : _indentReplacement(
              line,
              markup,
              indentationWidth: indentationWidth,
            );
      if (replacement != null) replacements.add(replacement);
    }

    if (line.end >= value.text.length) break;
    // _SourceLine excludes a possible carriage return, but the next logical
    // line always begins immediately after the newline character.
    final newline = value.text.indexOf('\n', line.end);
    if (newline < 0) break;
    lineStart = newline + 1;
  }

  if (replacements.isEmpty) return null;
  return _applyReplacements(value, replacements);
}

_TextReplacement _indentReplacement(
  _SourceLine line,
  _LineMarkup markup, {
  required int indentationWidth,
}) {
  if (markup.kind == _MarkupKind.blockquote) {
    return _TextReplacement(
      start: line.start + markup.contentStart,
      end: line.start + markup.contentStart,
      replacement: '> ',
    );
  }

  return _TextReplacement(
    start: line.start,
    end: line.start,
    replacement: ' ' * indentationWidth,
  );
}

_TextReplacement? _outdentReplacement(
  String document,
  _SourceLine line,
  _LineMarkup markup, {
  required int indentationWidth,
}) {
  if (markup.kind == _MarkupKind.blockquote && markup.quoteDepth > 1) {
    final removedSegment = markup.quoteSegments.last;
    return _TextReplacement(
      start: line.start + markup.contentStart - removedSegment.length,
      end: line.start + markup.contentStart,
      replacement: '',
    );
  }

  if (markup.indent.isEmpty) return null;
  final parentIndent = _findParentIndent(
    document,
    line.start,
    markup.indent,
    indentationWidth: indentationWidth,
  );
  return _TextReplacement(
    start: line.start,
    end: line.start + markup.indent.length,
    replacement: parentIndent,
  );
}

TextEditingValue _renumberFollowingOrderedItems(
  TextEditingValue value, {
  required int insertedItemCaret,
  required String indent,
  required int nextNumber,
  required int indentationWidth,
}) {
  final newlineAfterInsertedItem = value.text.indexOf('\n', insertedItemCaret);
  if (newlineAfterInsertedItem < 0) return value;

  final targetWidth = _indentWidth(indent, indentationWidth);
  final replacements = <_TextReplacement>[];
  var expectedNumber = nextNumber;
  var lineStart = newlineAfterInsertedItem + 1;

  while (lineStart <= value.text.length) {
    final line = _lineAt(value.text, lineStart);
    if (line.text.trim().isNotEmpty) {
      final markup = _LineMarkup.parse(line.text);
      if (markup != null) {
        final width = _indentWidth(markup.indent, indentationWidth);
        if (width < targetWidth) break;
        if (width == targetWidth) {
          if (markup.kind != _MarkupKind.orderedList) break;
          if (markup.orderedNumber != expectedNumber) {
            replacements.add(
              _TextReplacement(
                start: line.start + markup.orderedNumberStart!,
                end: line.start + markup.orderedNumberEnd!,
                replacement: '$expectedNumber',
              ),
            );
          }
          expectedNumber += 1;
        }
      } else {
        final leadingWhitespace = RegExp(r'^[ \t]*').firstMatch(line.text)![0]!;
        if (_indentWidth(leadingWhitespace, indentationWidth) <= targetWidth) {
          break;
        }
      }
    }

    if (line.end >= value.text.length) break;
    final newline = value.text.indexOf('\n', line.end);
    if (newline < 0) break;
    lineStart = newline + 1;
  }

  if (replacements.isEmpty) return value;
  return _applyReplacements(value, replacements);
}

TextEditingValue _exitOrOutdentEmptyMarkup(
  TextEditingValue value,
  _SourceLine line,
  _LineMarkup markup, {
  required int indentationWidth,
}) {
  final replacement = _markupOneLevelShallower(
    value.text,
    line,
    markup,
    indentationWidth: indentationWidth,
  );

  // Empty top-level items exit the container. Nested items retain their marker
  // at the shallower level. Replacing the whole line also discards harmless
  // trailing whitespace after an otherwise empty marker.
  return _replaceRange(value, line.start, line.end, replacement);
}

String _markupOneLevelShallower(
  String document,
  _SourceLine line,
  _LineMarkup markup, {
  required int indentationWidth,
}) {
  if (markup.kind == _MarkupKind.blockquote && markup.quoteDepth > 1) {
    return '${markup.indent}${markup.quoteSegments.take(markup.quoteDepth - 1).join()}';
  }

  if (markup.indent.isNotEmpty) {
    final parentIndent = _findParentIndent(
      document,
      line.start,
      markup.indent,
      indentationWidth: indentationWidth,
    );
    return '$parentIndent${markup.markerWithoutIndent}';
  }

  return '';
}

String _findParentIndent(
  String document,
  int currentLineStart,
  String currentIndent, {
  required int indentationWidth,
}) {
  var cursor = currentLineStart > 0 ? currentLineStart - 1 : -1;
  final currentWidth = _indentWidth(currentIndent, indentationWidth);

  while (cursor >= 0) {
    final previousLineStart = document.lastIndexOf('\n', cursor - 1) + 1;
    var previousLineEnd = cursor;
    if (previousLineEnd > previousLineStart &&
        document.codeUnitAt(previousLineEnd - 1) == 0x0D) {
      previousLineEnd -= 1;
    }
    final previousLine = document.substring(previousLineStart, previousLineEnd);
    final previousMarkup = _LineMarkup.parse(previousLine);
    if (previousMarkup != null) {
      final candidateWidth = _indentWidth(
        previousMarkup.indent,
        indentationWidth,
      );
      if (candidateWidth < currentWidth) return previousMarkup.indent;
    }

    if (previousLineStart == 0) break;
    cursor = previousLineStart - 1;
  }

  if (currentIndent.endsWith('\t')) {
    return currentIndent.substring(0, currentIndent.length - 1);
  }

  final removable = currentIndent.length < indentationWidth
      ? currentIndent.length
      : indentationWidth;
  return currentIndent.substring(0, currentIndent.length - removable);
}

int _indentWidth(String indent, int indentationWidth) {
  var width = 0;
  for (final codeUnit in indent.codeUnits) {
    width += codeUnit == 0x09 ? indentationWidth : 1;
  }
  return width;
}

bool _hasUsableSelection(TextEditingValue value) {
  final selection = value.selection;
  return selection.isValid &&
      selection.start >= 0 &&
      selection.end <= value.text.length;
}

TextEditingValue _replaceSelection(TextEditingValue value, String replacement) {
  return _replaceRange(
    value,
    value.selection.start,
    value.selection.end,
    replacement,
  );
}

TextEditingValue _insertAtCaret(TextEditingValue value, String insertion) {
  final caret = value.selection.extentOffset;
  return _replaceRange(value, caret, caret, insertion);
}

TextEditingValue _replaceRange(
  TextEditingValue value,
  int start,
  int end,
  String replacement,
) {
  final text = value.text.replaceRange(start, end, replacement);
  final caret = start + replacement.length;
  return value.copyWith(
    text: text,
    selection: TextSelection.collapsed(offset: caret),
    composing: TextRange.empty,
  );
}

TextEditingValue _applyReplacements(
  TextEditingValue value,
  List<_TextReplacement> replacements,
) {
  replacements.sort((a, b) => a.start.compareTo(b.start));

  final selection = value.selection;
  final mappedBase = _mapOffsetThroughReplacements(
    selection.baseOffset,
    replacements,
  );
  final mappedExtent = _mapOffsetThroughReplacements(
    selection.extentOffset,
    replacements,
  );

  var text = value.text;
  for (final replacement in replacements.reversed) {
    text = text.replaceRange(
      replacement.start,
      replacement.end,
      replacement.replacement,
    );
  }

  return value.copyWith(
    text: text,
    selection: TextSelection(
      baseOffset: mappedBase,
      extentOffset: mappedExtent,
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    ),
    composing: TextRange.empty,
  );
}

int _mapOffsetThroughReplacements(
  int offset,
  List<_TextReplacement> replacements,
) {
  var shift = 0;
  for (final replacement in replacements) {
    if (offset < replacement.start) break;
    final removedLength = replacement.end - replacement.start;
    final addedLength = replacement.replacement.length;

    if (removedLength == 0) {
      // At an insertion point the caret follows the original source text.
      shift += addedLength;
      continue;
    }

    if (offset <= replacement.end) {
      if (offset == replacement.end) {
        return offset + shift + addedLength - removedLength;
      }
      final relative = offset - replacement.start;
      final clampedRelative = relative > addedLength ? addedLength : relative;
      return replacement.start + shift + clampedRelative;
    }

    shift += addedLength - removedLength;
  }
  return offset + shift;
}

class _TableContext {
  const _TableContext({required this.table, required this.location});

  static _TableContext? maybeAt(String document, int offset) {
    final blocks = const MarkdownBlockParser().parse(document);
    MarkdownBlock? block;
    for (final candidate in blocks) {
      if (candidate.type == MarkdownBlockType.table &&
          offset >= candidate.sourceStart &&
          offset <= candidate.sourceEnd) {
        block = candidate;
        break;
      }
    }
    if (block == null) return null;
    final table = MarkdownTableSource.fromBlock(document, block);
    final location = table?.locationAt(offset);
    if (table == null || location == null) return null;
    return _TableContext(table: table, location: location);
  }

  final MarkdownTableSource table;
  final MarkdownTableLocation location;

  MarkdownBlock get block => table.block;
  List<MarkdownTableRow> get rows => table.rows;
  String get lineEnding => table.lineEnding;
  int get columnCount => table.columnCount;
  List<MarkdownTableLocation> get editableLocations => table.editableLocations;
}

class _TextReplacement {
  const _TextReplacement({
    required this.start,
    required this.end,
    required this.replacement,
  });

  final int start;
  final int end;
  final String replacement;
}

class _SourceLine {
  const _SourceLine({
    required this.start,
    required this.end,
    required this.text,
  });

  factory _SourceLine.at(String document, int offset) {
    final start = offset == 0 ? 0 : document.lastIndexOf('\n', offset - 1) + 1;
    final nextNewline = document.indexOf('\n', offset);
    var end = nextNewline < 0 ? document.length : nextNewline;
    if (end > start && document.codeUnitAt(end - 1) == 0x0D) end -= 1;
    return _SourceLine(
      start: start,
      end: end,
      text: document.substring(start, end),
    );
  }

  final int start;
  final int end;
  final String text;
}

_SourceLine _lineAt(String document, int offset) =>
    _SourceLine.at(document, offset);

enum _MarkupKind { unorderedList, orderedList, task, blockquote }

class _LineMarkup {
  const _LineMarkup({
    required this.kind,
    required this.indent,
    required this.markerWithoutIndent,
    required this.contentStart,
    required this.nextLinePrefix,
    required this.alignmentPrefix,
    this.quoteSegments = const <String>[],
    this.orderedNumber,
    this.orderedNumberStart,
    this.orderedNumberEnd,
  });

  factory _LineMarkup._fromMatch({
    required _MarkupKind kind,
    required RegExpMatch match,
    required String markerWithoutIndent,
    required String nextLineMarker,
    int? orderedNumber,
    int? orderedNumberStart,
    int? orderedNumberEnd,
  }) {
    final indent = match.group(1)!;
    return _LineMarkup(
      kind: kind,
      indent: indent,
      markerWithoutIndent: markerWithoutIndent,
      contentStart: match.end,
      nextLinePrefix: '$indent$nextLineMarker',
      alignmentPrefix: '$indent${' ' * markerWithoutIndent.length}',
      orderedNumber: orderedNumber,
      orderedNumberStart: orderedNumberStart,
      orderedNumberEnd: orderedNumberEnd,
    );
  }

  static _LineMarkup? parse(String line) {
    final task = RegExp(r'^([ \t]*)([-+*])([ \t]+)\[([ xX])\]([ \t]*)')
        .firstMatch(line);
    if (task != null) {
      final marker =
          '${task.group(2)}${task.group(3)}[${task.group(4)}]${task.group(5)}';
      final separator = task.group(5)!.isEmpty ? ' ' : task.group(5)!;
      final nextMarker = '${task.group(2)}${task.group(3)}[ ]$separator';
      return _LineMarkup._fromMatch(
        kind: _MarkupKind.task,
        match: task,
        markerWithoutIndent: marker,
        nextLineMarker: nextMarker,
      );
    }

    final unordered = RegExp(r'^([ \t]*)([-+*])([ \t]+)').firstMatch(line);
    if (unordered != null) {
      final marker = '${unordered.group(2)}${unordered.group(3)}';
      return _LineMarkup._fromMatch(
        kind: _MarkupKind.unorderedList,
        match: unordered,
        markerWithoutIndent: marker,
        nextLineMarker: marker,
      );
    }

    final ordered = RegExp(r'^([ \t]*)(\d{1,9})([.)])([ \t]+)')
        .firstMatch(line);
    if (ordered != null) {
      final marker =
          '${ordered.group(2)}${ordered.group(3)}${ordered.group(4)}';
      final number = int.parse(ordered.group(2)!) + 1;
      final nextMarker = '$number${ordered.group(3)}${ordered.group(4)}';
      return _LineMarkup._fromMatch(
        kind: _MarkupKind.orderedList,
        match: ordered,
        markerWithoutIndent: marker,
        nextLineMarker: nextMarker,
        orderedNumber: int.parse(ordered.group(2)!),
        orderedNumberStart: ordered.group(1)!.length,
        orderedNumberEnd: ordered.group(1)!.length + ordered.group(2)!.length,
      );
    }

    final quote = RegExp(r'^([ \t]*)((?:>[ \t]*)+)').firstMatch(line);
    if (quote != null) {
      final indent = quote.group(1)!;
      final marker = quote.group(2)!;
      final segments = RegExp(r'>[ \t]*')
          .allMatches(marker)
          .map((match) => match.group(0)!)
          .toList(growable: false);
      return _LineMarkup(
        kind: _MarkupKind.blockquote,
        indent: indent,
        markerWithoutIndent: marker,
        contentStart: quote.end,
        nextLinePrefix: '$indent$marker',
        alignmentPrefix: '$indent${' ' * marker.length}',
        quoteSegments: segments,
      );
    }

    return null;
  }

  final _MarkupKind kind;
  final String indent;
  final String markerWithoutIndent;
  final int contentStart;
  final String nextLinePrefix;
  final String alignmentPrefix;
  final List<String> quoteSegments;
  final int? orderedNumber;
  final int? orderedNumberStart;
  final int? orderedNumberEnd;

  int get quoteDepth => quoteSegments.length;

  String content(String line) => line.substring(contentStart);
}
