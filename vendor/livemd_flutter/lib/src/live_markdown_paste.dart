import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'live_markdown_media.dart';

/// Reads one clipboard snapshot in response to an explicit paste action.
///
/// Implementations own platform access. They must not read the clipboard in the
/// background, fetch URLs found in text, or return the same item once for each
/// of its available representations.
abstract interface class LiveMarkdownClipboard {
  /// Returns text and/or media from the same snapshot. A snapshot is disposed
  /// after importing, including on cancellation and failure.
  Future<LiveMarkdownClipboardSnapshot> read();
}

/// Optional native fallback for user-committed IME content without inline bytes.
abstract interface class LiveMarkdownKeyboardContentReader {
  Future<LiveMarkdownClipboardSnapshot> readKeyboardContent(
    KeyboardInsertedContent content,
  );
}

/// SDK-only text fallback. Android keyboard media insertion does not require a
/// native clipboard plugin when the input method supplies the media bytes.
class LiveMarkdownTextClipboard implements LiveMarkdownClipboard {
  const LiveMarkdownTextClipboard();
  @override
  Future<LiveMarkdownClipboardSnapshot> read() async =>
      LiveMarkdownClipboardSnapshot(
        text: (await Clipboard.getData(Clipboard.kTextPlain))?.text,
      );
}

/// An optional source of user-initiated paste events, for example a browser.
abstract interface class LiveMarkdownClipboardEventSource {
  /// Return an unsubscribe callback. Never claim an event before the editor
  /// has identified the focused, editable target that owns it.
  VoidCallback subscribe(
    void Function(LiveMarkdownClipboardEvent event) listener,
  );
}

abstract interface class LiveMarkdownClipboardEvent {
  bool get isClaimed;

  /// Claims the event synchronously, suppressing native insertion, and returns
  /// one owned snapshot asynchronously. Only one editor may claim an event.
  Future<LiveMarkdownClipboardSnapshot> claim();
}

/// A media item whose bytes are available for the duration of an import.
///
/// The application must consume [openRead] before its importer returns. The
/// stream is single-use unless the adapter explicitly documents otherwise.
class LiveMarkdownPasteMedia {
  const LiveMarkdownPasteMedia({
    required this.mimeType,
    required this.openRead,
    this.suggestedName,
    this.size,
  });

  final String mimeType;
  final String? suggestedName;
  final int? size;
  final Stream<List<int>> Function() openRead;
  LiveMarkdownMediaType? get type => liveMarkdownMediaTypeForMime(mimeType);
}

/// An owned clipboard read. Alternative formats for one item count as one item.
class LiveMarkdownClipboardSnapshot {
  LiveMarkdownClipboardSnapshot({
    this.text,
    List<LiveMarkdownPasteMedia> media = const [],
    this.hasUnsupportedMedia = false,
    this.onDispose,
  }) : media = List.unmodifiable(media);

  final String? text;
  final List<LiveMarkdownPasteMedia> media;

  /// True for file/media items the adapter cannot import. Such items must not
  /// silently fall back to a text representation such as their file path.
  final bool hasUnsupportedMedia;
  final FutureOr<void> Function()? onDispose;
  Future<void>? _disposal;

  /// Concurrent cleanup callers await the same release, including its error.
  Future<void> dispose() =>
      _disposal ??= Future<void>.sync(() => onDispose?.call());
}

/// Cooperative cancellation for an import. Late results are never inserted.
class LiveMarkdownPasteCancellation {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  /// Package integrations may cancel their own import request.
  void cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

/// A request to save/upload media; document insertion remains library-owned.
class LiveMarkdownMediaImportRequest {
  const LiveMarkdownMediaImportRequest({
    required this.operationId,
    required this.media,
    required this.cancellation,
    int? itemId,
    this.itemIndex = 0,
    this.itemCount = 1,
  }) : itemId = itemId ?? operationId;

  final int operationId;
  final LiveMarkdownPasteMedia media;
  final LiveMarkdownPasteCancellation cancellation;

  /// Unique per item; use this rather than the batch ID for storage names.
  final int itemId;
  final int itemIndex;
  final int itemCount;
}

/// An application-owned media reference to insert into Markdown.
///
/// Return a URL or a reference understood by the editor's imageResolver. This
/// is a destination, not a complete Markdown fragment. Returning null from the
/// importer explicitly rejects the import; throwing reports an import error.
class LiveMarkdownImportedMedia {
  const LiveMarkdownImportedMedia({required this.destination, this.alt = ''});

  final String destination;
  final String alt;
}

enum LiveMarkdownPasteStatus {
  inserted,
  textPasted,
  empty,
  unsupported,
  rejected,
  readFailed,
  importFailed,
  cancelled,
  busy,
}

/// Per-item outcome. Uploaded references may need application cleanup whenever
/// the enclosing batch was not inserted, even if this item imported successfully.
enum LiveMarkdownPasteItemStatus {
  imported,
  rejected,
  failed,
  cancelled,
  skipped,
}

class LiveMarkdownPasteItemResult {
  const LiveMarkdownPasteItemResult({
    required this.itemId,
    required this.itemIndex,
    required this.status,
    this.imported,
    this.error,
    this.stackTrace,
  });
  final int itemId;
  final int itemIndex;
  final LiveMarkdownPasteItemStatus status;
  final LiveMarkdownImportedMedia? imported;
  final Object? error;
  final StackTrace? stackTrace;
}

/// Terminal outcome of one paste attempt.
///
/// A cancelled operation is reported after its importer settles, so [imported]
/// can identify an uploaded file that was never inserted. Applications own its
/// cleanup. The request's cancellation signal is delivered immediately.
class LiveMarkdownPasteResult {
  const LiveMarkdownPasteResult({
    required this.operationId,
    required this.status,
    this.imported,
    this.error,
    this.stackTrace,
    this.items = const [],
  });

  final int operationId;
  final LiveMarkdownPasteStatus status;
  final LiveMarkdownImportedMedia? imported;
  final Object? error;
  final StackTrace? stackTrace;
  final List<LiveMarkdownPasteItemResult> items;

  /// All successfully imported references, including unused uploads from a
  /// cancelled or failed batch. The legacy [imported] field covers a single item.
  Iterable<LiveMarkdownImportedMedia> get importedMedia => items.isEmpty
      ? (imported == null ? const [] : [imported!])
      : items
            .map((item) => item.imported)
            .whereType<LiveMarkdownImportedMedia>();
}

/// Optional media paste integration. One batch inserts atomically and forms one
/// undo step. Storage, playback and progress UI belong to the application.
@immutable
class LiveMarkdownPasteConfiguration {
  const LiveMarkdownPasteConfiguration({
    this.clipboard = const LiveMarkdownTextClipboard(),
    required this.onImportMedia,
    this.onResult,
    this.allowedMimeTypes = const [
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
      'image/bmp',
      'video/*',
      'audio/*',
    ],
    this.contentInsertionMimeTypes = const [
      'image/png',
      'image/jpeg',
      'image/gif',
      'image/webp',
    ],
    this.maxItems = 32,
    this.maxConcurrentImports = 2,
  }) : assert(maxItems > 0),
       assert(maxConcurrentImports > 0);

  final LiveMarkdownClipboard clipboard;
  final Future<LiveMarkdownImportedMedia?> Function(
    LiveMarkdownMediaImportRequest request,
  )
  onImportMedia;
  final ValueChanged<LiveMarkdownPasteResult>? onResult;
  final List<String> allowedMimeTypes;

  /// Android keyboard MIME advertisement. An empty list disables this entry.
  final List<String> contentInsertionMimeTypes;
  final int maxItems;
  final int maxConcurrentImports;

  bool acceptsMimeType(String mimeType) {
    final mime = mimeType.split(';').first.trim().toLowerCase();
    if (liveMarkdownMediaTypeForMime(mime) == null) return false;
    return allowedMimeTypes.any((allowed) {
      final pattern = allowed.toLowerCase();
      return pattern == mime ||
          (pattern.endsWith('/*') &&
              mime.startsWith(pattern.substring(0, pattern.length - 1)));
    });
  }
}
