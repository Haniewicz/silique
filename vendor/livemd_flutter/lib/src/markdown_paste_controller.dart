import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_markdown_controller.dart';
import 'live_markdown_paste.dart';
import 'markdown_block.dart';
import 'markdown_block_parser.dart';
import 'markdown_document_mutation.dart';
import 'markdown_syntax_tree.dart';
import 'markdown_table.dart';

enum MarkdownPasteArea {
  document,
  tableCell,
  tableSource,
  calloutTitle,
  calloutBody,
}

/// Describes the editing surface without retaining its widget or focus node.
class MarkdownPasteTarget {
  const MarkdownPasteTarget({
    required this.selection,
    this.area = MarkdownPasteArea.document,
    this.containerStart,
    this.row,
    this.column,
  });

  final TextSelection selection;
  final MarkdownPasteArea area;
  final int? containerStart;
  final int? row;
  final int? column;

  bool accepts(String text, TextRange range, int? container) {
    if (!range.isValid || range.end > text.length) return false;
    if (area == MarkdownPasteArea.document) return true;
    final blocks = const MarkdownBlockParser().parse(text);
    final matches = blocks.where((block) => block.sourceStart == container);
    if (matches.isEmpty) return false;
    final block = matches.first;
    if (range.start < block.sourceStart || range.end > block.sourceEnd) {
      return false;
    }
    switch (area) {
      case MarkdownPasteArea.document:
        return true;
      case MarkdownPasteArea.tableSource:
        return block.type == MarkdownBlockType.table;
      case MarkdownPasteArea.tableCell:
        final table = MarkdownTableSource.fromBlock(text, block);
        if (table == null ||
            row == null ||
            column == null ||
            row! >= table.rows.length) {
          return false;
        }
        final cells = table.rows[row!].cells;
        if (column! >= cells.length) return false;
        final cell = cells[column!];
        return range.isCollapsed && cell.contentStart == cell.contentEnd
            ? range.start == cell.editingOffset
            : range.start >= cell.contentStart && range.end <= cell.contentEnd;
      case MarkdownPasteArea.calloutTitle:
      case MarkdownPasteArea.calloutBody:
        if (block.type != MarkdownBlockType.callout) return false;
        final header = RegExp(r'^\s*>\s*\[![^\]]+\][+-]?[^\S\r\n]*(.*)')
            .firstMatch(block.source);
        if (header == null) return false;
        final titleEnd = block.sourceStart + header.end;
        final titleStart = titleEnd - header.group(1)!.length;
        return area == MarkdownPasteArea.calloutTitle
            ? range.start >= titleStart && range.end <= titleEnd
            : range.start > titleEnd;
    }
  }
}

/// True when media would become literal code rather than a media projection.
bool markdownPasteIsCode(String text, TextRange range) {
  bool touches(int start, int end) => range.isCollapsed
      ? range.start > start && range.start < end
      : range.start < end && range.end > start;
  for (final block in const MarkdownBlockParser().parse(text)) {
    if (block.type == MarkdownBlockType.codeFence &&
        touches(block.sourceStart, block.sourceEnd)) {
      return true;
    }
  }
  bool containsCode(Iterable<MarkdownInlineNode> nodes) {
    for (final node in nodes) {
      if (node.kind == MarkdownInlineKind.codeSpan &&
          touches(node.fullRange.start, node.fullRange.end)) {
        return true;
      }
      if (containsCode(node.inlines)) return true;
    }
    return false;
  }

  return const MarkdownSyntaxParser()
      .parse(text)
      .lines
      .any((line) => containsCode(line.inlines));
}

/// A single-line embed. Angle destinations preserve spaces/parentheses;
/// Markdown escaping preserves literal punctuation without URL re-encoding.
String serializeMarkdownPaste(LiveMarkdownImportedMedia media) {
  if (media.destination.isEmpty ||
      RegExp(r'[\r\n\x00-\x1f]').hasMatch(media.destination)) {
    throw const FormatException(
      'A media destination must be nonempty and contain no control characters.',
    );
  }
  String escape(String value, String punctuation) {
    final output = StringBuffer();
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      if (punctuation.contains(character)) output.write('\\');
      output.write(character);
    }
    return output.toString();
  }

  final alt = escape(
    media.alt.replaceAll(RegExp(r'[\r\n\x00-\x1f]'), ' '),
    r'\[]|',
  );
  final destination = escape(media.destination, r'\<>|');
  return '![$alt](<$destination>)';
}

String serializeMarkdownPasteBatch(
  List<LiveMarkdownImportedMedia> media,
  MarkdownPasteTarget target,
  String source,
  TextRange range,
) {
  final fragments = media.map(serializeMarkdownPaste).toList();
  if (fragments.length < 2) return fragments.single;
  if (target.area == MarkdownPasteArea.tableCell ||
      target.area == MarkdownPasteArea.tableSource ||
      target.area == MarkdownPasteArea.calloutTitle) {
    return fragments.join(' ');
  }
  final lineStart = range.start == 0
      ? 0
      : source.lastIndexOf('\n', range.start - 1) + 1;
  final end = source.indexOf('\n', range.end);
  final before = source.substring(lineStart, range.start);
  final after = source.substring(range.end, end < 0 ? source.length : end);
  final quote = RegExp(r'^[ \t]*(?:>[ \t]?)+').firstMatch(before)?.group(0);
  if (after.trim().isEmpty &&
      quote != null &&
      before.substring(quote.length).trim().isEmpty) {
    return fragments.join('\n$quote');
  }
  if (before.trim().isEmpty && after.trim().isEmpty) {
    return fragments.join('\n\n$before');
  }
  return fragments.join(' ');
}

/// The rendering boundary consumes decoded destinations; the document remains
/// byte-for-byte Markdown source, including its escape characters.
String unescapeMarkdownMedia(String value) => value.replaceAllMapped(
  RegExp(r'\\([!"#$%&\x27()*+,\-./:;<=>?@\[\]\\^_`{|}~])'),
  (match) => match.group(1)!,
);

class MarkdownPasteController {
  MarkdownPasteController(this.document, this.configuration) {
    document.mutations.addListener(_onMutation);
  }

  final LiveMarkdownController document;
  LiveMarkdownPasteConfiguration configuration;
  static int _nextId = 0;
  static int _nextItemId = 0;
  _PasteSession? _active;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    _cancel();
    document.mutations.removeListener(_onMutation);
  }

  void _cancel() {
    _active?.cancel();
    _active = null;
  }

  void _onMutation(MarkdownDocumentMutation mutation) {
    final session = _active;
    if (session == null) return;
    if (mutation.invalidate) {
      _cancel();
      return;
    }
    if (mutation.before.text != mutation.after.text) {
      final edit = mutation.edit;
      if (edit == null) {
        _cancel();
        return;
      }
      final mapped = mapMarkdownPasteRange(session.range, edit);
      if (mapped == null) {
        _cancel();
        return;
      }
      session.range = mapped;
      if (mutation.after.selection.start != mapped.start ||
          mutation.after.selection.end != mapped.end) {
        session.selectionMoved = true;
      }
      final container = session.container;
      if (container != null) {
        if (edit.end <= container && edit.start < container) {
          session.container = container + edit.delta;
        } else if (edit.start <= container && edit.end > container) {
          _cancel();
          return;
        }
      }
    } else if (mutation.before.selection != mutation.after.selection) {
      session.selectionMoved = true;
    }
    final composing = mutation.after.composing;
    if (!session.target.accepts(
          mutation.after.text,
          session.range,
          session.container,
        ) ||
        (composing.isValid &&
            !composing.isCollapsed &&
            composing.start <= session.range.end &&
            composing.end >= session.range.start)) {
      _cancel();
    }
  }

  Future<void> paste(
    MarkdownPasteTarget target, {
    required bool Function(String text, TextRange target) pasteText,
    Future<LiveMarkdownClipboardSnapshot>? capturedSnapshot,
  }) async {
    if (_disposed) {
      await _discard(capturedSnapshot);
      return;
    }
    final configuration = this.configuration;
    final id = ++_nextId;
    if (_active != null) {
      await _discard(capturedSnapshot);
      _report(
        LiveMarkdownPasteResult(
          operationId: id,
          status: LiveMarkdownPasteStatus.busy,
        ),
        configuration,
      );
      return;
    }
    final range = TextRange(
      start: target.selection.start,
      end: target.selection.end,
    );
    if (!target.selection.isValid ||
        !target.accepts(document.text, range, target.containerStart)) {
      await _discard(capturedSnapshot);
      _report(
        LiveMarkdownPasteResult(
          operationId: id,
          status: LiveMarkdownPasteStatus.cancelled,
        ),
        configuration,
      );
      return;
    }
    final initialComposing = document.composing;
    final beganComposing =
        initialComposing.isValid && !initialComposing.isCollapsed;
    final session = _PasteSession(target, range);
    _active = session;
    unawaited(
      session.cancellation.whenCancelled.then((_) {
        if (identical(_active, session)) _active = null;
      }),
    );
    LiveMarkdownClipboardSnapshot? snapshot;
    var items = <LiveMarkdownPasteItemResult>[];
    var status = LiveMarkdownPasteStatus.empty;
    Object? error;
    StackTrace? stackTrace;
    var importing = false;
    try {
      snapshot = await (capturedSnapshot ?? configuration.clipboard.read());
      final ownedSnapshot = snapshot;
      unawaited(
        session.cancellation.whenCancelled.then((_) async {
          try {
            await ownedSnapshot.dispose();
          } catch (_) {
            /* awaited below */
          }
        }),
      );
      if (session.cancellation.isCancelled) {
        status = session.stopReason ?? LiveMarkdownPasteStatus.cancelled;
      } else {
        final hasMedia =
            snapshot.media.isNotEmpty || snapshot.hasUnsupportedMedia;
        final code = markdownPasteIsCode(document.text, session.range);
        if (!hasMedia || code) {
          final text = snapshot.text;
          if (text != null && text.isNotEmpty) {
            _active = null;
            status = pasteText(text, session.range)
                ? LiveMarkdownPasteStatus.textPasted
                : LiveMarkdownPasteStatus.cancelled;
          } else {
            status = hasMedia
                ? LiveMarkdownPasteStatus.unsupported
                : LiveMarkdownPasteStatus.empty;
          }
        } else if (snapshot.hasUnsupportedMedia ||
            snapshot.media.length > configuration.maxItems ||
            snapshot.media.any(
              (media) => !configuration.acceptsMimeType(media.mimeType),
            )) {
          status = LiveMarkdownPasteStatus.unsupported;
        } else if (beganComposing ||
            (document.composing.isValid && !document.composing.isCollapsed)) {
          status = LiveMarkdownPasteStatus.cancelled;
        } else {
          importing = true;
          items = await _importBatch(
            id,
            snapshot.media,
            session,
            configuration,
          );
          final failures = items.where((item) => item.error != null);
          if (failures.isNotEmpty) {
            error = failures.first.error;
            stackTrace = failures.first.stackTrace;
          }
          if (session.cancellation.isCancelled || _disposed) {
            status = session.stopReason ?? LiveMarkdownPasteStatus.cancelled;
          } else if (!target.accepts(
                document.text,
                session.range,
                session.container,
              ) ||
              markdownPasteIsCode(document.text, session.range)) {
            status = LiveMarkdownPasteStatus.cancelled;
          } else {
            final imported = items.map((item) => item.imported!).toList();
            final markdown = serializeMarkdownPasteBatch(
              imported,
              target,
              document.text,
              session.range,
            );
            final edit = MarkdownSourceEdit(
              session.range.start,
              session.range.end,
              markdown.length,
            );
            final current = document.selection;
            final selection = session.selectionMoved
                ? TextSelection(
                    baseOffset: mapMarkdownOffset(current.baseOffset, edit),
                    extentOffset: mapMarkdownOffset(current.extentOffset, edit),
                    affinity: current.affinity,
                    isDirectional: current.isDirectional,
                  )
                : TextSelection.collapsed(
                    offset: session.range.start + markdown.length,
                  );
            final composing = document.composing;
            final nextComposing = composing.isValid && !composing.isCollapsed
                ? TextRange(
                    start: mapMarkdownOffset(composing.start, edit),
                    end: mapMarkdownOffset(composing.end, edit),
                  )
                : TextRange.empty;
            _active = null;
            document.replaceRange(
              session.range.start,
              session.range.end,
              markdown,
              selection: selection,
              composing: nextComposing,
              origin: Object(),
            );
            status = LiveMarkdownPasteStatus.inserted;
          }
        }
      }
    } catch (caught, stack) {
      error = caught;
      stackTrace = stack;
      status =
          session.stopReason ??
          (session.cancellation.isCancelled
              ? LiveMarkdownPasteStatus.cancelled
              : importing
              ? LiveMarkdownPasteStatus.importFailed
              : LiveMarkdownPasteStatus.readFailed);
    } finally {
      if (identical(_active, session)) _active = null;
      try {
        await snapshot?.dispose();
      } catch (caught, stack) {
        error ??= caught;
        stackTrace ??= stack;
      }
    }
    _report(
      LiveMarkdownPasteResult(
        operationId: id,
        status: status,
        imported: items.length == 1 ? items.single.imported : null,
        items: List.unmodifiable(items),
        error: error,
        stackTrace: stackTrace,
      ),
      configuration,
    );
  }

  Future<List<LiveMarkdownPasteItemResult>> _importBatch(
    int operationId,
    List<LiveMarkdownPasteMedia> media,
    _PasteSession session,
    LiveMarkdownPasteConfiguration configuration,
  ) async {
    final ids = List.generate(media.length, (_) => ++_nextItemId);
    final results = List.generate(
      media.length,
      (index) => LiveMarkdownPasteItemResult(
        itemId: ids[index],
        itemIndex: index,
        status: LiveMarkdownPasteItemStatus.skipped,
      ),
    );
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < media.length && !session.cancellation.isCancelled) {
        final index = cursor++;
        LiveMarkdownImportedMedia? imported;
        try {
          imported = await configuration.onImportMedia(
            LiveMarkdownMediaImportRequest(
              operationId: operationId,
              itemId: ids[index],
              itemIndex: index,
              itemCount: media.length,
              media: media[index],
              cancellation: session.cancellation,
            ),
          );
          if (imported != null) serializeMarkdownPaste(imported);
          results[index] = LiveMarkdownPasteItemResult(
            itemId: ids[index],
            itemIndex: index,
            status: imported != null
                ? LiveMarkdownPasteItemStatus.imported
                : session.cancellation.isCancelled
                ? LiveMarkdownPasteItemStatus.cancelled
                : LiveMarkdownPasteItemStatus.rejected,
            imported: imported,
          );
          if (imported == null && !session.cancellation.isCancelled) {
            session.cancel(LiveMarkdownPasteStatus.rejected);
          }
        } catch (error, stack) {
          results[index] = LiveMarkdownPasteItemResult(
            itemId: ids[index],
            itemIndex: index,
            status: LiveMarkdownPasteItemStatus.failed,
            imported: imported,
            error: error,
            stackTrace: stack,
          );
          if (!session.cancellation.isCancelled) {
            session.cancel(LiveMarkdownPasteStatus.importFailed);
          }
        }
      }
    }

    await Future.wait(
      List.generate(
        configuration.maxConcurrentImports.clamp(1, media.length),
        (_) => worker(),
      ),
    );
    return results;
  }

  Future<void> _discard(Future<LiveMarkdownClipboardSnapshot>? snapshot) async {
    if (snapshot == null) return;
    try {
      await (await snapshot).dispose();
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription(
            'while releasing an unused clipboard snapshot',
          ),
        ),
      );
    }
  }

  void _report(
    LiveMarkdownPasteResult result,
    LiveMarkdownPasteConfiguration configuration,
  ) {
    try {
      configuration.onResult?.call(result);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          context: ErrorDescription('while reporting a Markdown paste result'),
        ),
      );
    }
  }
}

class _PasteSession {
  _PasteSession(this.target, this.range) : container = target.containerStart;
  final MarkdownPasteTarget target;
  TextRange range;
  int? container;
  bool selectionMoved = false;
  final cancellation = LiveMarkdownPasteCancellation();
  LiveMarkdownPasteStatus? stopReason;
  void cancel([
    LiveMarkdownPasteStatus reason = LiveMarkdownPasteStatus.cancelled,
  ]) {
    stopReason ??= reason;
    cancellation.cancel();
  }
}
