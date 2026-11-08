import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

/// Invoked only by an explicit editor paste, never by focus/clipboard status.
class NativeImageClipboard
    implements LiveMarkdownClipboard, LiveMarkdownKeyboardContentReader {
  const NativeImageClipboard();
  static const channel = MethodChannel('silique.notes/clipboard');
  static const maxBytes = 10 * 1024 * 1024;
  static const maxPixels = 16 * 1024 * 1024;
  static const mimeTypes = [
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  ];

  @override
  Future<LiveMarkdownClipboardSnapshot> read() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const LiveMarkdownTextClipboard().read();
    }
    return snapshot(await channel.invokeMapMethod<String, dynamic>('read'));
  }

  @override
  Future<LiveMarkdownClipboardSnapshot> readKeyboardContent(
    KeyboardInsertedContent content,
  ) async {
    final uri = Uri.tryParse(content.uri);
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        uri?.scheme != 'content' ||
        !mimeTypes.contains(content.mimeType)) {
      throw const FormatException('Unsupported IME content');
    }
    return snapshot(
      await channel.invokeMapMethod<String, dynamic>('readUri', {
        'uri': content.uri,
        'mimeType': content.mimeType,
      }),
    );
  }

  static LiveMarkdownClipboardSnapshot snapshot(Map<String, dynamic>? value) {
    final media = <LiveMarkdownPasteMedia>[];
    final owned = <Uint8List>[];
    for (final item in (value?['media'] as List? ?? const [])) {
      final map = item as Map;
      final bytes = map['bytes'] as Uint8List;
      final mime = map['mimeType'] as String;
      if (bytes.isEmpty ||
          bytes.length > maxBytes ||
          !mimeTypes.contains(mime)) {
        throw const FormatException('Unsupported clipboard image');
      }
      owned.add(bytes);
      media.add(
        LiveMarkdownPasteMedia(
          mimeType: mime,
          size: bytes.length,
          openRead: () => Stream.value(bytes),
        ),
      );
    }
    return LiveMarkdownClipboardSnapshot(
      text: value?['text'] as String?,
      media: media,
      hasUnsupportedMedia: value?['hasUnsupportedMedia'] == true,
      onDispose: () {
        for (final bytes in owned) {
          bytes.fillRange(0, bytes.length, 0);
        }
      },
    );
  }
}

/// Validate bytes before an encrypted attachment import. Hidden notes omit the
/// importer and retain the image inside their separately encrypted document.
Future<LiveMarkdownImportedMedia?> importClipboardImage(
  LiveMarkdownMediaImportRequest request, {
  required bool Function() isCurrent,
  Future<String> Function(Uint8List bytes, String mime)? saveImage,
}) async {
  final mime = request.media.mimeType.toLowerCase();
  if (!NativeImageClipboard.mimeTypes.contains(mime) || !isCurrent()) {
    return null;
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in request.media.openRead()) {
    if (!isCurrent() || request.cancellation.isCancelled) return null;
    if (builder.length + chunk.length > NativeImageClipboard.maxBytes) {
      throw const FormatException('Clipboard image is too large');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.isEmpty || !isCurrent() || request.cancellation.isCancelled) {
    return null;
  }
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((v) => v);
  final detected = starts([137, 80, 78, 71, 13, 10, 26, 10])
      ? 'image/png'
      : starts([255, 216, 255])
      ? 'image/jpeg'
      : starts([71, 73, 70, 56])
      ? 'image/gif'
      : starts([66, 77])
      ? 'image/bmp'
      : bytes.length >= 12 &&
            ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
            ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP'
      ? 'image/webp'
      : null;
  if (detected != mime) {
    throw const FormatException('Clipboard image MIME mismatch');
  }
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      if (descriptor.width <= 0 ||
          descriptor.height <= 0 ||
          descriptor.width * descriptor.height >
              NativeImageClipboard.maxPixels) {
        throw const FormatException('Clipboard image dimensions are too large');
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
  if (!isCurrent() || request.cancellation.isCancelled) return null;
  final destination = saveImage == null
      ? 'data:$mime;base64,${base64Encode(bytes)}'
      : await saveImage(bytes, mime);
  if (!isCurrent() || request.cancellation.isCancelled) return null;
  return LiveMarkdownImportedMedia(destination: destination, alt: 'image');
}
