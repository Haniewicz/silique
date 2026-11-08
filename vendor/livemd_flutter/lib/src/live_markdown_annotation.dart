import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';

/// A presentation-only overlay for a source range.
///
/// Annotations never change the Markdown source, the undo history or the
/// selection. They are rebuilt on every projection, so callers can use them for
/// transient highlights such as search results. Offsets are UTF-16 code units
/// in the same document as [LiveMarkdownController.text].
@immutable
class LiveMarkdownAnnotation {
  const LiveMarkdownAnnotation({
    required this.start,
    required this.end,
    this.backgroundColor,
    this.fontSize,
  }) : assert(end >= start);

  /// Inclusive start offset.
  final int start;

  /// Exclusive end offset.
  final int end;

  /// Painted behind the affected glyphs.
  final Color? backgroundColor;

  /// Overrides the effective font size of the affected glyphs.
  final double? fontSize;

  /// Whether this annotation affects any source offset; empty ranges are ignored.
  bool get isVisible => end > start;

  @override
  bool operator ==(Object other) =>
      other is LiveMarkdownAnnotation &&
      other.start == start &&
      other.end == end &&
      other.backgroundColor == backgroundColor &&
      other.fontSize == fontSize;

  @override
  int get hashCode => Object.hash(start, end, backgroundColor, fontSize);

  @override
  String toString() =>
      'LiveMarkdownAnnotation($start..$end, fontSize: $fontSize)';
}