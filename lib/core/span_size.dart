import 'package:flutter/services.dart' show TextSelection;

import 'dart:ui' show TextRange;

/// Minimum and maximum size of an inline font-size run, in logical pixels.
const minSpanFontSize = 8.0;
const maxSpanFontSize = 72.0;

final _openTag = RegExp(r'<span style="font-size:(\d{1,2}(?:\.\d)?)px">');

/// Inline Markdown that carries a font size for exactly one run of text.
///
/// `<span style="font-size:20px">…</span>` is inline HTML, which is valid
/// Markdown, survives every existing storage, sync, export and import path as
/// plain note text, and is rendered by the bundled `livemd_flutter` editor.
String openSpanFontSizeTag(num size) =>
    '<span style="font-size:${_formatSize(size)}px">';

/// Closing marker paired with [openSpanFontSizeTag].
const closeSpanFontSizeTag = '</span>';

String _formatSize(num size) {
  final value = size.clamp(minSpanFontSize, maxSpanFontSize).toDouble();
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
}

/// Returns the size of the run that exactly wraps [selection], if any.
double? spanFontSizeAt(String text, TextSelection selection) {
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;
  final open = _openTag
      .allMatches(text)
      .where((match) => match.end == range.start)
      .firstOrNull;
  if (open == null) return null;
  if (!text.startsWith(closeSpanFontSizeTag, range.end)) return null;
  return double.tryParse(open.group(1)!);
}

/// Applies an inline font size to exactly [selection].
///
/// The function never falls back to the whole document: a collapsed selection
/// returns `null`. Multi-line selections are wrapped line by line, so each line
/// gets its own persistent Markdown span. Re-applying a size to an already
/// formatted run rewrites that run instead of nesting another span.
({String text, TextSelection selection})? applySpanFontSize(
  String text,
  TextSelection selection,
  num size,
) {
  if (!size.isFinite) return null;
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;
  final px = size.clamp(minSpanFontSize, maxSpanFontSize);

  // Re-formatting an already formatted run rewrites its size instead of nesting
  // another span. For a multi-line selection every line has its own run, so all
  // of them are updated.
  final rewritable = <RegExpMatch>[
    for (final match in _openTag.allMatches(text))
      if (match.end >= range.start && match.end <= range.end) match,
  ];
  if (rewritable.isNotEmpty &&
      rewritable.first.end == range.start &&
      text.startsWith(closeSpanFontSizeTag, range.end)) {
    final tag = openSpanFontSizeTag(px);
    final buffer = StringBuffer();
    var cursor = 0;
    var newStart = range.start;
    var newEnd = range.end;
    for (final match in rewritable) {
      buffer
        ..write(text.substring(cursor, match.start))
        ..write(tag);
      final delta = tag.length - (match.end - match.start);
      if (match.end <= range.start) newStart += delta;
      newEnd += delta;
      cursor = match.end;
    }
    buffer.write(text.substring(cursor));
    return (
      text: buffer.toString(),
      selection: TextSelection(baseOffset: newStart, extentOffset: newEnd),
    );
  }

  final tag = openSpanFontSizeTag(px);
  final buffer = StringBuffer();
  var cursor = 0;
  var newStart = -1;
  var newEnd = -1;
  var lineStart = range.start;
  for (var i = range.start; i <= range.end; i++) {
    final atEnd = i == range.end;
    if (!atEnd && text.codeUnitAt(i) != 0x0a) continue;
    final lineEnd = i;
    final line = text.substring(lineStart, lineEnd);
    buffer.write(text.substring(cursor, lineStart));
    cursor = lineEnd;
    if (line.trim().isEmpty) {
      buffer.write(line);
    } else {
      buffer.write(tag);
      // Offsets in the returned selection refer to the new string, not to the
      // original one, so they are taken from the output buffer length.
      if (newStart < 0) newStart = buffer.length;
      buffer.write(line);
      newEnd = buffer.length;
      buffer.write(closeSpanFontSizeTag);
    }
    if (!atEnd) {
      buffer.write('\n');
      cursor = lineEnd + 1;
      lineStart = lineEnd + 1;
    }
  }
  if (newStart < 0) return null;
  buffer.write(text.substring(cursor));
  return (
    text: buffer.toString(),
    selection: TextSelection(baseOffset: newStart, extentOffset: newEnd),
  );
}

TextRange _normalized(String text, TextSelection selection) {
  final start = selection.start.clamp(0, text.length);
  final end = selection.end.clamp(0, text.length);
  return TextRange(start: start < end ? start : end, end: end);
}
