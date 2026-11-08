import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../services/notebook.dart';

class AttachmentImage extends ImageProvider<AttachmentImage> {
  AttachmentImage(this.notebook, this.vaultId, this.id)
    : access = identityHashCode(notebook.unlocked[vaultId]);
  final Notebook notebook;
  final String vaultId, id;
  final int access;
  @override
  Future<AttachmentImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    AttachmentImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(decode),
    scale: 1,
    debugLabel: 'Silique image attachment',
  );
  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    final bytes = await notebook.imageBytes(vaultId, id);
    return decode(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (width, height) => width > 1600
          ? ui.TargetImageSize(width: 1600)
          : ui.TargetImageSize(width: width, height: height),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AttachmentImage &&
      identical(notebook, other.notebook) &&
      vaultId == other.vaultId &&
      id == other.id &&
      access == other.access;
  @override
  int get hashCode => Object.hash(notebook, vaultId, id, access);
}
