import '../l10n/strings.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show MethodChannel;
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';

Future<({String title, String body})?> importMarkdown() async {
  final file = await openFile(
    acceptedTypeGroups: [
      const XTypeGroup(
        label: 'Markdown',
        extensions: ['md', 'markdown', 'txt'],
        mimeTypes: ['text/markdown', 'text/plain'],
      ),
    ],
  );
  if (file == null) return null;
  if (await file.length() > 1000000) {
    throw FormatException(
      tr(
        'Plik jest zbyt duży (limit 1 MB).',
        'The file is too large (limit: 1 MB).',
      ),
    );
  }
  return (
    title: file.name.replaceFirst(RegExp(r'\.(md|markdown|txt)$'), ''),
    body: await file.readAsString(),
  );
}

Future<void> exportMarkdown(Note note) async {
  final name =
      '${note.title.replaceAll(RegExp(r'[^\p{L}\p{N} _-]', unicode: true), '_')}.md';
  final bytes = utf8.encode('# ${note.title}\n\n${note.body}');
  if (Platform.isAndroid || Platform.isIOS) {
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: 'text/markdown', name: name)],
        fileNameOverrides: [name],
      ),
    );
  } else {
    final location = await getSaveLocation(
      suggestedName: name,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Markdown', extensions: ['md']),
      ],
    );
    if (location != null) {
      await File(location.path).writeAsBytes(bytes, flush: true);
    }
  }
}

/// Result of the location picker.
///
/// On Android the system returns a SAF tree, which only sometimes maps onto a
/// filesystem path. [path] is `null` then: SQLite cannot use a tree URI, so the
/// UI must ask the user for an explicit alternative instead of pretending the
/// grant is usable.
class StorageChoice {
  const StorageChoice({this.path, this.label, this.writable = true});
  final String? path;
  final String? label;
  final bool writable;
  bool get usable => path != null && writable;
}

/// Test seams: the platform picker and the keychain/bookmark channel cannot run
/// in widget tests, so tests can replace exactly these two calls.
@visibleForTesting
Future<StorageChoice?> Function()? debugDirectoryPicker;

@visibleForTesting
void Function(String path)? debugStorageAccess;

Future<StorageChoice?> chooseStorageDirectory() async {
  final override = debugDirectoryPicker;
  if (override != null) return override();
  if (Platform.isAndroid) {
    final result = await const MethodChannel('silique.notes/storage')
        .invokeMapMethod<String, Object?>('pick');
    if (result == null) return null;
    return StorageChoice(
      path: result['path'] as String?,
      label: result['label'] as String?,
      writable: result['writable'] as bool? ?? false,
    );
  }
  final path = await getDirectoryPath(
    confirmButtonText: tr('Wybierz miejsce zapisu', 'Choose storage location'),
  );
  if (path == null) return null;
  return StorageChoice(path: path, label: path);
}

/// Legacy constant retained for callers that use it in const collections.
/// UI pickers must use [localizedImageTypes] so their label follows the language.
const imageTypes = XTypeGroup(
  label: 'Zdjęcia',
  extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'],
  mimeTypes: [
    'image/png',
    'image/jpeg',
    'image/gif',
    'image/webp',
    'image/bmp',
  ],
);
XTypeGroup get localizedImageTypes => XTypeGroup(
  label: tr('Zdjęcia', 'Images'),
  extensions: imageTypes.extensions,
  mimeTypes: imageTypes.mimeTypes,
);

Future<XFile?> pickImage() =>
    openFile(acceptedTypeGroups: [localizedImageTypes]);

Future<({Uint8List bytes, String mime, String name})> readImageFile(
  XFile file,
) async {
  final bytes = await file.readAsBytes();
  String? mime;
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((value) => value);
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) mime = 'image/png';
  if (starts([255, 216, 255])) mime = 'image/jpeg';
  if (starts([71, 73, 70, 56])) mime = 'image/gif';
  if (starts([66, 77])) mime = 'image/bmp';
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    mime = 'image/webp';
  }
  if (mime == null) {
    throw FormatException(
      tr(
        'Plik „${file.name}” nie jest obsługiwanym zdjęciem (PNG, JPEG, GIF, WebP, BMP).',
        'File “${file.name}” is not a supported image (PNG, JPEG, GIF, WebP, BMP).',
      ),
    );
  }
  return (bytes: bytes, mime: mime, name: file.name);
}

Future<void> removePromisedImage(XFile file) async {
  final root = Directory.systemTemp.absolute.path;
  final path = File(file.path).absolute.path;
  if (path.startsWith('$root/') && path.contains('/Drops/')) {
    final target = File(path);
    if (await target.exists()) await target.delete();
  }
}

Future<void> restoreStorageAccess() async {
  if (!Platform.isMacOS) return;
  final support = await getApplicationSupportDirectory();
  final pointer = File('${support.path}/silique-location.txt');
  if (await pointer.exists()) {
    await const MethodChannel('silique.notes/storage')
        .invokeMethod<void>('restore', (await pointer.readAsString()).trim());
  }
}

Future<void> rememberStorageAccess(String path) async {
  final override = debugStorageAccess;
  if (override != null) {
    override(path);
    return;
  }
  if (Platform.isMacOS) {
    await const MethodChannel('silique.notes/storage')
        .invokeMethod<void>('remember', path);
  }
}

/// Whether Settings can move the whole store to another directory.
///
/// Android uses the same native folder picker as the first run: the chosen
/// directory is validated, remembered (persistable tree grant) and the database,
/// Markdown mirrors and attachments are copied with their keys untouched.
bool get canMoveStorage => !Platform.isIOS;
