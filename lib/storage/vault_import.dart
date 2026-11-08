import '../l10n/strings.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/workspace.dart';

const _channel = MethodChannel('silique.notes/import');
const importEntryLimit = 20000;
const importByteLimit = 256 * 1024 * 1024;
const importMetadataNames = {
  '.obsidian',
  '.git',
  '.trash',
  '.DS_Store',
  'Thumbs.db',
};
final importNoteExtension = RegExp(
  r'\.(md|markdown|txt)$',
  caseSensitive: false,
);

class ImportEntry {
  const ImportEntry(this.path, {required this.directory});
  final String path;
  final bool directory;
}

abstract class VaultImportSource {
  String get label;
  Future<List<ImportEntry>> entries();
  Future<Uint8List> read(String path, {required int limit});
}

/// A selected document is the complete scope of a single-file import. Never
/// enumerate its parent or resolve adjacent images without an explicit grant.
class MarkdownFileImportSource implements VaultImportSource {
  MarkdownFileImportSource(this.file);
  final XFile file;
  @override
  String get label => file.name;
  @override
  Future<List<ImportEntry>> entries() async {
    if (!importNoteExtension.hasMatch(label) ||
        !_relativePath(label) ||
        label.contains('/')) {
      throw FormatException(
        tr('Wybierz plik Markdown lub TXT.', 'Choose a Markdown or TXT file.'),
      );
    }
    return [ImportEntry(label, directory: false)];
  }

  @override
  Future<Uint8List> read(String path, {required int limit}) async {
    if (path != label) {
      throw FormatException(
        tr('Nieprawidłowa ścieżka importu.', 'Invalid import path.'),
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw FormatException(
          tr(
            'Plik jest zbyt duży (limit 1 MB).',
            'The file is too large (limit: 1 MB).',
          ),
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

@visibleForTesting
Future<XFile?> Function()? debugMarkdownImportPicker;

Future<VaultImportSource?> pickMarkdownImportSource() async {
  final file =
      await (debugMarkdownImportPicker?.call() ??
          openFile(
            acceptedTypeGroups: [
              const XTypeGroup(
                label: 'Markdown',
                extensions: ['md', 'markdown', 'txt'],
                mimeTypes: ['text/markdown', 'text/plain'],
              ),
            ],
          ));
  return file == null ? null : MarkdownFileImportSource(file);
}

class DirectoryImportSource implements VaultImportSource {
  DirectoryImportSource(String path) : root = Directory(path).absolute;
  final Directory root;
  @override
  String get label => root.uri.pathSegments.where((s) => s.isNotEmpty).last;

  @override
  Future<List<ImportEntry>> entries() async {
    final result = <ImportEntry>[];
    Future<void> visit(Directory dir) async {
      await for (final entity in dir.list(followLinks: false)) {
        final name = entity.path.split(Platform.pathSeparator).last;
        if (importMetadataNames.contains(name)) continue;
        if (entity is Link) {
          throw FormatException(
            tr(
              'Folder zawiera dowiązanie: $name. Usuń je z kopii do importu.',
              'The folder contains a symbolic link: $name. Remove it from the import copy.',
            ),
          );
        }
        final path = entity.path
            .substring(root.path.length + 1)
            .replaceAll(Platform.pathSeparator, '/');
        result.add(ImportEntry(path, directory: entity is Directory));
        if (result.length > importEntryLimit) {
          throw FormatException(
            tr(
              'Import obejmuje więcej niż 20 000 plików i folderów. Podziel go na części.',
              'The import contains more than 20,000 files and folders. Split it into smaller parts.',
            ),
          );
        }
        if (entity is Directory) {
          if (path.split('/').length > maxFolderDepth) {
            throw FormatException(
              tr(
                'Folder „$path” ma więcej niż $maxFolderDepth poziomów.',
                'Folder “$path” has more than $maxFolderDepth levels.',
              ),
            );
          }
          await visit(entity);
        }
      }
    }

    await visit(root);
    return result;
  }

  @override
  Future<Uint8List> read(String path, {required int limit}) async {
    if (!_relativePath(path)) {
      throw FormatException(
        tr('Nieprawidłowa ścieżka importu.', 'Invalid import path.'),
      );
    }
    final target = File(
      '${root.path}/${path.replaceAll('/', Platform.pathSeparator)}',
    );
    final resolvedRoot = await root.resolveSymbolicLinks();
    final resolved = await target.resolveSymbolicLinks();
    if (!resolved.startsWith('$resolvedRoot${Platform.pathSeparator}')) {
      throw FormatException(
        tr(
          'Plik jest poza wybranym folderem: $path',
          'The file is outside the selected folder: $path',
        ),
      );
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in target.openRead()) {
      if (bytes.length + chunk.length > limit) {
        throw FormatException(
          tr(
            'Plik „$path” przekracza limit importu.',
            'File “$path” exceeds the import limit.',
          ),
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }
}

class _AndroidImportSource implements VaultImportSource {
  _AndroidImportSource(this.label, this.token);
  @override
  final String label;
  final String token;
  @override
  Future<List<ImportEntry>> entries() async {
    final rows = await _channel.invokeListMethod<Object?>('list', {
      'token': token,
    });
    return [
      for (final row in rows ?? [])
        ImportEntry(
          (row as Map)['path'] as String,
          directory: row['directory'] as bool,
        ),
    ];
  }

  @override
  Future<Uint8List> read(String path, {required int limit}) async =>
      (await _channel.invokeMethod<Uint8List>('read', {
        'token': token,
        'path': path,
        'limit': limit,
      }))!;
}

@visibleForTesting
Future<VaultImportSource?> Function()? debugVaultImportPicker;

Future<VaultImportSource?> pickVaultImportSource() async {
  if (debugVaultImportPicker != null) return debugVaultImportPicker!();
  if (Platform.isAndroid) {
    final value = await _channel.invokeMapMethod<String, Object?>('pick');
    return value == null
        ? null
        : _AndroidImportSource(
            value['label'] as String,
            value['token'] as String,
          );
  }
  final path = await getDirectoryPath(
    confirmButtonText: tr(
      'Wybierz folder z notatkami',
      'Choose a notes folder',
    ),
  );
  return path == null ? null : DirectoryImportSource(path);
}

bool _relativePath(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.split('/').any((s) => s.isEmpty || s == '.' || s == '..');

class ImportedNote {
  const ImportedNote(this.path, this.title, this.body);
  final String path, title, body;
  String get folder =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

class VaultImportPlan {
  VaultImportPlan(
    this.source,
    this.notes,
    this.folders,
    this.files,
    this.unsupported,
  );
  final VaultImportSource source;
  final List<ImportedNote> notes;
  final List<String> folders;
  final Set<String> files;
  final List<String> unsupported;
}

Future<VaultImportPlan> scanVaultImport(VaultImportSource source) async {
  final entries = [...await source.entries()];
  if (entries.length > importEntryLimit) {
    throw FormatException(
      tr(
        'Zbyt wiele plików do jednego importu.',
        'Too many files for a single import.',
      ),
    );
  }
  final files = <String>{}, folders = <String>{}, unsupported = <String>[];
  final notes = <ImportedNote>[];
  var total = 0;
  for (final entry in entries..sort((a, b) => a.path.compareTo(b.path))) {
    if (!_relativePath(entry.path)) {
      throw FormatException(
        tr(
          'Nieprawidłowa ścieżka: ${entry.path}',
          'Invalid path: ${entry.path}',
        ),
      );
    }
    if (entry.path.split('/').any(importMetadataNames.contains)) continue;
    if (entry.directory) {
      if (normalizeFolderPath(entry.path) != entry.path) {
        throw FormatException(
          tr(
            'Folder „${entry.path}” nie mieści się w limitach Silique: ${folderPathError(entry.path) ?? 'zmień jego nazwę'}.',
            'Folder “${entry.path}” exceeds Silique limits: ${folderPathError(entry.path) ?? 'rename it'}.',
          ),
        );
      }
      folders.add(entry.path);
      continue;
    }
    files.add(entry.path);
    if (!importNoteExtension.hasMatch(entry.path)) {
      if (importImageMime(entry.path) == null) unsupported.add(entry.path);
      continue;
    }
    final bytes = await source.read(entry.path, limit: 1000000);
    total += bytes.length;
    if (total > importByteLimit) {
      throw FormatException(
        tr(
          'Import przekracza 256 MB. Podziel go na części.',
          'The import exceeds 256 MB. Split it into smaller parts.',
        ),
      );
    }
    String body;
    if (bytes.length >= 2 &&
        ((bytes[0] == 255 && bytes[1] == 254) ||
            (bytes[0] == 254 && bytes[1] == 255))) {
      if (bytes.length.isOdd) {
        throw FormatException(
          tr(
            'Uszkodzony plik UTF-16: ${entry.path}',
            'Corrupted UTF-16 file: ${entry.path}',
          ),
        );
      }
      final data = ByteData.sublistView(bytes);
      body = String.fromCharCodes([
        for (var i = 2; i < bytes.length; i += 2)
          data.getUint16(i, bytes[0] == 255 ? Endian.little : Endian.big),
      ]);
    } else {
      try {
        body = utf8.decode(bytes);
      } on FormatException {
        throw FormatException(
          tr(
            'Plik „${entry.path}” nie jest tekstem UTF-8 ani UTF-16.',
            'File “${entry.path}” is not UTF-8 or UTF-16 text.',
          ),
        );
      }
    }
    if (body.startsWith('\ufeff')) body = body.substring(1);
    final name = entry.path
        .split('/')
        .last
        .replaceFirst(importNoteExtension, '');
    notes.add(ImportedNote(entry.path, name, body));
  }
  if (notes.isEmpty) {
    throw FormatException(
      tr(
        'Nie znaleziono notatek Markdown ani TXT w wybranym folderze.',
        'No Markdown or TXT notes were found in the selected folder.',
      ),
    );
  }
  return VaultImportPlan(
    source,
    notes,
    folders.toList()..sort(),
    files,
    unsupported,
  );
}

String? importImageMime(String path) =>
    switch (path.split('.').last.toLowerCase()) {
      'png' => 'image/png',
      'jpg' || 'jpeg' => 'image/jpeg',
      'gif' => 'image/gif',
      'webp' => 'image/webp',
      'bmp' => 'image/bmp',
      _ => null,
    };

/// Resolve relative Markdown paths and Obsidian root/basename paths without
/// traversing outside the chosen source. Ambiguous names are never guessed.
String? resolveImportLink(String note, String raw, Set<String> files) {
  var target = raw.trim();
  if (target.startsWith('<') && target.endsWith('>')) {
    target = target.substring(1, target.length - 1);
  }
  final uri = Uri.tryParse(target);
  if (uri == null || uri.hasScheme || target.startsWith('//')) {
    return null;
  }
  final literal = target.split('#').first;
  try {
    // Uri normalizes raw Unicode and stray '%' before decoding. Decoding the
    // original Obsidian filename directly can throw ArgumentError on either.
    final decoded = Uri.decodeComponent(uri.toString().split('#').first);
    final path = _resolveImportPath(note, decoded, files);
    if (path != null) return path;
  } on FormatException {
    // A literal filename may contain escapes that are not valid UTF-8 (%FF).
  }
  return _resolveImportPath(note, literal, files);
}

String? _resolveImportPath(String note, String target, Set<String> files) {
  if (target.isEmpty) return null;
  String? normalize(String candidate) {
    final parts = <String>[];
    for (final part in candidate.split('/')) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (parts.isEmpty) return null;
        parts.removeLast();
      } else {
        parts.add(part);
      }
    }
    return parts.join('/');
  }

  final parent = note.contains('/')
      ? note.substring(0, note.lastIndexOf('/'))
      : '';
  for (final rawPath in [
    if (!target.startsWith('/')) '$parent/$target',
    target,
  ]) {
    final path = normalize(rawPath);
    if (path == null) continue;
    if (files.contains(path)) return path;
    for (final ext in ['.md', '.markdown', '.txt']) {
      if (files.contains('$path$ext')) return '$path$ext';
    }
  }
  if (target.contains('/') || target == '..') return null;
  final matches = files
      .where(
        (p) =>
            p.split('/').last == target ||
            p.split('/').last.replaceFirst(importNoteExtension, '') == target,
      )
      .toList();
  return matches.length == 1 ? matches.single : null;
}

/// Leave fenced/inline code verbatim while translating real links and embeds.
Future<String> rewriteImportedBody(
  String body,
  Future<String?> Function(String target, String label, bool image) resolve,
) async {
  final mask = body.split('');
  var offset = 0;
  String? fence;
  for (final line in body.split('\n')) {
    final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})').firstMatch(line)?.group(1);
    final inside = fence != null;
    if (fence == null && marker != null) {
      fence = marker;
    } else if (fence != null &&
        marker != null &&
        marker[0] == fence[0] &&
        marker.length >= fence.length &&
        line.trim() == marker) {
      fence = null;
    }
    if (inside || fence != null || marker != null) {
      for (var i = offset; i < offset + line.length; i++) {
        mask[i] = ' ';
      }
    }
    offset += line.length + 1;
  }
  for (final m in RegExp(r'(`+).*?\1').allMatches(mask.join())) {
    for (var i = m.start; i < m.end; i++) {
      mask[i] = ' ';
    }
  }
  final pattern = RegExp(
    r'(!?)\[\[([^\]\n]+)\]\]|(!?)\[([^\]\n]*)\]\((<[^>\n]+>|(?:\\.|[^()\\\n]|\([^()\n]*\))+)\)',
  );
  final output = StringBuffer();
  var start = 0;
  for (final match in pattern.allMatches(mask.join())) {
    output.write(body.substring(start, match.start));
    final wiki = match.group(2);
    var target = wiki == null ? match.group(5)!.trim() : wiki.split('|').first;
    if (wiki == null && !target.startsWith('<')) {
      target = target.replaceFirst(RegExp(r'''\s+["'][^"']*["']$'''), '');
    }
    final label = wiki == null
        ? match.group(4)!
        : wiki.contains('|')
        ? wiki.substring(wiki.indexOf('|') + 1)
        : wiki;
    output.write(
      await resolve(
            target,
            label,
            (wiki == null ? match.group(3) : match.group(1)) == '!',
          ) ??
          body.substring(match.start, match.end),
    );
    start = match.end;
  }
  output.write(body.substring(start));
  return output.toString();
}
