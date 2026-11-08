/// The broad Markdown construct represented by a [MarkdownBlock].
enum MarkdownBlockType {
  blank,
  paragraph,
  heading,
  blockquote,
  callout,
  list,
  table,
  codeFence,
  thematicBreak,
}

/// A lossless slice of the source Markdown document.
class MarkdownBlock {
  /// Describes [source] at the half-open document range [sourceStart]–[sourceEnd].
  const MarkdownBlock({
    required this.type,
    required this.sourceStart,
    required this.sourceEnd,
    required this.source,
  });

  /// Broad construct used for block rendering.
  final MarkdownBlockType type;
  /// Inclusive document offset in UTF-16 code units.
  final int sourceStart;
  /// Exclusive document offset in UTF-16 code units.
  final int sourceEnd;
  /// Exact source slice, including any retained line endings and delimiters.
  final String source;

  /// Tests source containment; [isLast] admits an end-of-document caret.
  /// A zero-length block contains its single boundary offset.
  bool containsOffset(int offset, {required bool isLast}) {
    if (sourceStart == sourceEnd) return offset == sourceStart;
    return offset >= sourceStart &&
        (offset < sourceEnd || (isLast && offset == sourceEnd));
  }

  @override
  String toString() =>
      'MarkdownBlock($type, $sourceStart..$sourceEnd, ${source.length} chars)';
}
