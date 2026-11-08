import 'package:flutter/material.dart';

/// A [TextEditingController] that paints search matches behind the source text.
///
/// The ranges are presentation-only: they never change the text, the undo
/// history or the selection. Offsets are UTF-16 code units, the same units that
/// [TextSelection] and the Markdown syntax tree use.
class HighlightingTextController extends TextEditingController {
  HighlightingTextController({super.text});

  List<TextRange> _matches = const [];
  int _active = -1;
  Color matchColor = const Color(0x66ffd54f);
  Color activeMatchColor = const Color(0xccffb300);

  /// Replaces the painted matches and the highlighted active match.
  set matches(({List<TextRange> ranges, int active}) value) {
    final sorted = [...value.ranges]
      ..sort((a, b) => a.start.compareTo(b.start));
    if (value.active == _active &&
        sorted.length == _matches.length &&
        Iterable<int>.generate(sorted.length)
            .every((i) => sorted[i] == _matches[i])) {
      return;
    }
    _matches = sorted;
    _active = value.active;
    notifyListeners();
  }

  /// Index of the match that contains [start], or `-1`.
  ///
  /// Segments are cut at match boundaries, so a segment is either inside one
  /// match or outside all of them. Binary search keeps painting linear in the
  /// number of matches instead of quadratic.
  int _matchIndexAt(int start) {
    var low = 0, high = _matches.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final match = _matches[mid];
      if (start < match.start) {
        high = mid - 1;
      } else if (start >= match.end) {
        low = mid + 1;
      } else {
        return mid;
      }
    }
    return -1;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final composing = value.composing;
    final showComposing = withComposing && composing.isValid;
    if (_matches.isEmpty && !showComposing) {
      return TextSpan(text: text, style: base);
    }
    final cuts = <int>{0, text.length};
    for (final match in _matches) {
      if (match.start > 0 && match.start < text.length) cuts.add(match.start);
      if (match.end > 0 && match.end < text.length) cuts.add(match.end);
    }
    if (showComposing) {
      if (composing.start > 0 && composing.start < text.length) {
        cuts.add(composing.start);
      }
      if (composing.end > 0 && composing.end < text.length) {
        cuts.add(composing.end);
      }
    }
    final ordered = cuts.toList()..sort();
    final spans = <InlineSpan>[];
    for (var i = 0; i + 1 < ordered.length; i++) {
      final start = ordered[i];
      final end = ordered[i + 1];
      if (start >= end) continue;
      var segment = base;
      final activeIndex = _matchIndexAt(start);
      if (activeIndex >= 0) {
        segment = segment.copyWith(
          backgroundColor: activeIndex == _active
              ? activeMatchColor
              : matchColor,
        );
      }
      if (showComposing && start >= composing.start && end <= composing.end) {
        segment = segment.copyWith(decoration: TextDecoration.underline);
      }
      spans.add(TextSpan(text: text.substring(start, end), style: segment));
    }
    return TextSpan(style: base, children: spans);
  }
}
