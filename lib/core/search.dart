import 'dart:ui' show TextRange;

/// Case-insensitive literal search over Markdown source.
///
/// Offsets are UTF-16 code units, exactly like Flutter text selections, so the
/// results can be passed back to `TextEditingController.selection`. Lowercasing
/// is only used when it preserves the length of the original string; otherwise
/// the query is matched case-sensitively. This keeps offsets correct for
/// Turkish dotted/dotless i and for any future Unicode case-folding change,
/// while Polish letters (`ą`, `ć`, `ę`, `ł`, `ń`, `ó`, `ś`, `ź`, `ż`) keep
/// their offsets in both modes.
List<TextRange> findMatchRanges(String text, String query) {
  if (query.isEmpty || text.isEmpty) return const [];
  var source = text;
  var needle = query;
  final lowerText = text.toLowerCase();
  final lowerQuery = query.toLowerCase();
  if (lowerText.length == text.length && lowerQuery.length == query.length) {
    source = lowerText;
    needle = lowerQuery;
  }
  final matches = <TextRange>[];
  var cursor = 0;
  while (cursor <= source.length - needle.length) {
    final index = source.indexOf(needle, cursor);
    if (index < 0) break;
    matches.add(TextRange(start: index, end: index + needle.length));
    cursor = index + needle.length;
  }
  return matches;
}

/// Index of the match that contains [offset], or `-1`.
int activeMatchForOffset(List<TextRange> matches, int offset) {
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    if (offset >= match.start && offset <= match.end) return i;
  }
  return -1;
}
