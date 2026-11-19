import 'dart:ui' show Color, TextRange;

import 'package:flutter/services.dart' show TextSelection;

/// Default transparency of a highlight run, written to Markdown with at most
/// two decimal places (e.g. `0.35`).
const double defaultHighlightAlpha = 0.35;

/// Closing marker shared by the color and highlight span forms.
const String closeSpanColorTag = '</span>';
const String closeSpanHighlightTag = '</span>';

/// `<span style="color:#RRGGBB">…</span>` opening tags, uppercase hex.
///
/// The detector tolerates the whitespace a hand-edited note may carry
/// (`color: #ff0000`), which the bundled parser renders as well, so a colored
/// run is never visible without being editable through the toolbar.
final RegExp _colorOpenTag = RegExp(
  r'<span style="\s*color\s*:\s*#([0-9A-Fa-f]{6})\s*">',
);

/// `<span style="background-color:rgba(R,G,B,A)">…</span>` with A in 0..1 and
/// at most two decimal places; whitespace relaxed like [_colorOpenTag].
final RegExp _highlightOpenTag = RegExp(
  r'<span style="\s*background-color\s*:\s*rgba\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(0(?:\.\d{1,2})?|1(?:\.0{1,2})?)\s*\)\s*">',
);

/// Inline Markdown that carries a text color for exactly one run of text.
///
/// `<span style="color:#RRGGBB">…</span>` is inline HTML, valid Markdown, and
/// survives every existing storage, sync, export and import path unchanged.
String openSpanColorTag(Color color) {
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '<span style="color:#'
      '${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}">';
}

/// Inline Markdown that carries a translucent background for one run of text.
String openSpanHighlightTag(Color color) {
  final argb = color.toARGB32();
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  final a = _formatAlpha(((argb >> 24) & 0xFF) / 255.0);
  return '<span style="background-color:rgba($r,$g,$b,$a)">';
}

String _formatAlpha(double value) {
  var text = value.clamp(0.0, 1.0).toStringAsFixed(2);
  if (text.contains('.')) {
    text = text.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
  }
  return text.isEmpty ? '0' : text;
}

/// Returns the text color of the run that exactly wraps [selection], if any.
Color? spanColorAt(String text, TextSelection selection) {
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;
  final open = _colorOpenTag
      .allMatches(text)
      .where((match) => match.end == range.start)
      .firstOrNull;
  if (open == null) return null;
  if (!text.startsWith(closeSpanColorTag, range.end)) return null;
  return _parseHexColor(open.group(1)!);
}

/// Returns the highlight color of the run that exactly wraps [selection], if any.
Color? spanHighlightAt(String text, TextSelection selection) {
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;
  final open = _highlightOpenTag
      .allMatches(text)
      .where((match) => match.end == range.start)
      .firstOrNull;
  if (open == null) return null;
  if (!text.startsWith(closeSpanHighlightTag, range.end)) return null;
  return _parseRgbaColor(open);
}

/// Applies an inline text color to exactly [selection].
///
/// A collapsed selection returns `null`. Multi-line selections are wrapped line
/// by line; empty lines are skipped. Re-applying a color to an already colored
/// run rewrites that run instead of nesting another span.
({String text, TextSelection selection})? applySpanColor(
  String text,
  TextSelection selection,
  Color color,
) => _applyInlineSpan(
  text,
  selection,
  openSpanColorTag(color),
  _colorOpenTag,
  closeSpanColorTag,
);

/// Applies a translucent inline highlight to exactly [selection]; see
/// [applySpanColor] for the wrapping and re-application rules.
({String text, TextSelection selection})? applySpanHighlight(
  String text,
  TextSelection selection,
  Color color,
) => _applyInlineSpan(
  text,
  selection,
  openSpanHighlightTag(color),
  _highlightOpenTag,
  closeSpanHighlightTag,
);

/// Removes the text color span that exactly wraps [selection], if any.
({String text, TextSelection selection})? removeSpanColor(
  String text,
  TextSelection selection,
) => _removeInlineSpan(text, selection, _colorOpenTag, closeSpanColorTag);

/// Removes the highlight span that exactly wraps [selection], if any.
({String text, TextSelection selection})? removeSpanHighlight(
  String text,
  TextSelection selection,
) => _removeInlineSpan(
  text,
  selection,
  _highlightOpenTag,
  closeSpanHighlightTag,
);

/// Wraps every non-empty physical line of [selection] in [openTag]…[closeTag],
/// or rewrites an existing run of the same form when the selection is already
/// exactly wrapped. Offsets in the returned selection refer to the new string.
({String text, TextSelection selection})? _applyInlineSpan(
  String text,
  TextSelection selection,
  String openTag,
  RegExp openTagPattern,
  String closeTag,
) {
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;

  // Re-formatting an already formatted run rewrites it instead of nesting.
  final rewritable = <RegExpMatch>[
    for (final match in openTagPattern.allMatches(text))
      if (match.end >= range.start && match.end <= range.end) match,
  ];
  if (rewritable.isNotEmpty &&
      rewritable.first.end == range.start &&
      text.startsWith(closeTag, range.end)) {
    final buffer = StringBuffer();
    var cursor = 0;
    var newStart = range.start;
    var newEnd = range.end;
    for (final match in rewritable) {
      buffer
        ..write(text.substring(cursor, match.start))
        ..write(openTag);
      final delta = openTag.length - (match.end - match.start);
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
      buffer.write(openTag);
      if (newStart < 0) newStart = buffer.length;
      buffer.write(line);
      newEnd = buffer.length;
      buffer.write(closeTag);
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

({String text, TextSelection selection})? _removeInlineSpan(
  String text,
  TextSelection selection,
  RegExp openTagPattern,
  String closeTag,
) {
  if (!selection.isValid) return null;
  final range = _normalized(text, selection);
  if (range.isCollapsed) return null;
  final open = openTagPattern
      .allMatches(text)
      .where((match) => match.end == range.start)
      .firstOrNull;
  if (open == null) return null;
  if (!text.startsWith(closeTag, range.end)) return null;
  final removedOpen = open.end - open.start;
  final buffer = StringBuffer()
    ..write(text.substring(0, open.start))
    ..write(text.substring(open.end, range.end))
    ..write(text.substring(range.end + closeTag.length));
  return (
    text: buffer.toString(),
    selection: TextSelection(
      baseOffset: range.start - removedOpen,
      extentOffset: range.end - removedOpen,
    ),
  );
}

Color _parseHexColor(String hex) =>
    Color(0xFF000000 | int.parse(hex, radix: 16));

Color _parseRgbaColor(RegExpMatch match) {
  int component(String group) => int.parse(group).clamp(0, 255);
  final r = component(match.group(1)!);
  final g = component(match.group(2)!);
  final b = component(match.group(3)!);
  final a = double.parse(match.group(4)!);
  return Color.fromARGB((a * 255).round().clamp(0, 255), r, g, b);
}

TextRange _normalized(String text, TextSelection selection) {
  final start = selection.start.clamp(0, text.length);
  final end = selection.end.clamp(0, text.length);
  return TextRange(start: start < end ? start : end, end: end);
}
