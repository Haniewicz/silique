import '../l10n/strings.dart';

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Pure, UI- and Platform-free export plan logic.
///
/// Every name/path decision lives here so it can be tested without a device,
/// a picker or Flutter bindings. The [VaultExportPlan] is a plain value:
/// [ExportVaultWriter] turns it into files on disk and [buildVaultExportZip]
/// turns it into an in-memory archive for mobile sharing.

/// Reserved top-level directory names inside an export root.
const exportImagesDir = '_images';
const exportHiddenDir = '_hidden';

/// Sanitizes a single file or directory name segment.
///
/// The existing single-note export rule is
/// `replaceAll(RegExp(r'[^\p{L}\p{N} _-]', unicode: true), '_')`; this keeps
/// exactly the same rule for titles so the two exports stay consistent. Note
/// that the rule replaces dots with `_` too (dot is not in the allowed set), so
/// `Ala.txt` becomes `Ala_txt` — do not "fix" that here, it would desync the
/// exports. On top of the shared rule we also:
///   * trim surrounding whitespace,
///   * strip a leading dot (would make a hidden file) and a trailing dot or
///     space (Windows rejects those),
///   * fall back to `tr('Bez tytułu','Untitled')` when nothing remains.
String sanitizeExportSegment(String raw) {
  // First trim and strip leading/trailing/consecutive dots and spaces, so
  // `Ala...` becomes `Ala` (not `Ala___`) and `...` becomes empty (→ Untitled).
  var value = raw.trim();
  value = value.replaceFirst(RegExp(r'^[. ]+'), '');
  value = value.replaceFirst(RegExp(r'[. ]+$'), '');
  // Then apply the shared single-note rule: dots are NOT in the allowed set so
  // any remaining ones become `_`. Legitimate underscores are preserved.
  value = value.replaceAll(RegExp(r'[^\p{L}\p{N} _-]', unicode: true), '_');
  return value.isEmpty ? tr('Bez tytułu', 'Untitled') : value;
}

/// Reserves names inside one directory with macOS/Windows-safe case folding.
///
/// Multiple reservations in the same directory are compared case-insensitively,
/// so `Note` and `NOTE` cannot silently become two files. A collision appends
/// `" (1)"`, then `" (2)"` and so on; a name already carrying a suffix simply
/// increments from that base, so reserving `["Ala","Ala","Ala (1)"]` yields
/// `["Ala.md","Ala (1).md","Ala (1) (1).md"]`.
class ExportPathAllocator {
  ExportPathAllocator();
  final Set<String> _taken = <String>{};

  String _key(String name) => name.toLowerCase();

  /// Reserves [name] and returns the final, collision-free name.
  String reserve(String name) {
    var candidate = name;
    var index = 1;
    while (!_taken.add(_key(candidate))) {
      candidate = '$name ($index)';
      index++;
    }
    return candidate;
  }
}

/// A note file prepared for export.
class ExportNoteFile {
  ExportNoteFile({
    required this.noteId,
    required this.title,
    required this.body,
    required this.folderPath,
    required this.relativeDir,
    required this.fileName,
    required this.hidden,
  });

  final String noteId;
  final String title;
  final String body;

  /// Vault folder path (empty string == root).
  final String folderPath;

  /// Directory of the note relative to the export root; `''` is the root and
  /// the hidden folder holds hidden notes.
  final String relativeDir;

  /// Final `.md` file name (dedup suffix already applied).
  final String fileName;
  final bool hidden;

  /// Full path relative to the export root, always with `/` separators.
  String get relativePath =>
      relativeDir.isEmpty ? fileName : '$relativeDir/$fileName';

  /// Depth used to build `../_images/...` links: a root note is depth 0, a note
  /// in one folder is depth 1, and so on.
  int get depth => relativeDir.isEmpty ? 0 : relativeDir.split('/').length;

  String get content => '# $title\n\n$body';
}

/// An image file prepared for export.
class ExportImageFile {
  ExportImageFile({
    required this.imageId,
    required this.fileName,
    required this.bytes,
  });
  final String imageId;

  /// File name inside `_images` (with a real image extension, deduplicated).
  final String fileName;
  final Uint8List bytes;
  String get relativePath => '$exportImagesDir/$fileName';
}

/// A deterministic, ready-to-write export plan.
class VaultExportPlan {
  VaultExportPlan({
    required this.notes,
    required this.images,
    required this.folders,
    required this.hiddenCount,
    required this.skippedImageCount,
  });
  final List<ExportNoteFile> notes;
  final List<ExportImageFile> images;

  /// Every directory to create under the export root, including empty vault
  /// folders and the reserved `_images`/`_hidden` directories, deduplicated and
  /// in creation order. The writer creates each one (even when no note lands in
  /// it) and the ZIP builder adds a trailing-slash entry, so empty folders
  /// survive a round-trip.
  final List<String> folders;
  final int hiddenCount;

  /// References that stayed verbatim because their bytes were unavailable.
  final int skippedImageCount;
}

/// A note with only the fields the export needs (keeps the pure module decoupled
/// from the app's [Note] model / crypto).
class ExportNote {
  ExportNote({
    required this.id,
    required this.title,
    required this.body,
    this.folder = '',
    this.hidden = false,
  });
  final String id, title, body, folder;
  final bool hidden;
}

/// Matches a `silique-image:<uuid>` reference in a note body. This is the
/// single source of truth for the export image link contract.
///
/// MUST STAY IN SYNC with `imageReferencePattern` in
/// `lib/services/notebook_images.dart` — both must match the exact same
/// `silique-image:<uuid>` shape.
final imageReference = RegExp(r'silique-image:([a-f0-9-]{36})');

/// Builds the export plan for [notes] and the resolved [images].
///
/// [notes] are the already-prepared notes (visible + optionally hidden, trash
/// already excluded). [images] maps a `silique-image:<id>` reference to its
/// bytes; references missing from [images] are kept verbatim and counted as
/// skipped. [folders] is the vault's full folder list (empty folders included),
/// as returned by `Notebook.foldersOf`/`allFolders`; every path is split into
/// segments here. A note's folder is its own [ExportNote.folder] field (split
/// in this builder), so mirroring is driven by both the note paths and the
/// empty folders.
///
/// Folder mirrors are built segment by segment; each segment is sanitized and
/// deduplicated case-insensitively within its parent. `_images` and `_hidden`
/// are reserved at the root so a vault folder named `_images` (case-insensitive)
/// becomes `_images (1)`. Hidden notes always go to the reserved top-level
/// `_hidden` directory (which itself yields `_hidden (1)` if a normal folder
/// already claimed the name), so they cannot leak into the ordinary tree.
///
/// The same case-insensitive allocator is shared per parent by both note folder
/// segments and empty-folder segments, so an empty folder and a note folder
/// that differ only in letter case collapse into one on-disk directory instead
/// of producing two sibling directories. Every intermediate directory (empty
/// folders and every ancestor) is recorded in [VaultExportPlan.folders], in
/// creation order, so the writer and the ZIP builder can materialize empty
/// directories too.
///
/// Image references in note bodies are rewritten to `../_images/<file>` paths
/// relative to each note's depth, always with `/` separators.
VaultExportPlan buildVaultExportPlan(
  List<ExportNote> notes, {
  Map<String, Uint8List> images = const {},
  List<String> folders = const [],
}) {
  // Deterministic input order: title (case-insensitive), then id.
  final ordered = notes.toList()
    ..sort((a, b) {
      final byTitle = a.title.toLowerCase().compareTo(b.title.toLowerCase());
      return byTitle != 0 ? byTitle : a.id.compareTo(b.id);
    });

  // Root allocator reserves the two reserved directories first so ordinary
  // folders cannot claim them. `_hidden` is reserved only when hidden notes
  // exist; its `reserve` may then yield `_hidden (1)` if a folder already
  // claimed `_hidden`.
  final rootAlloc = ExportPathAllocator();
  rootAlloc.reserve(exportImagesDir);
  final hasHidden = ordered.any((n) => n.hidden);
  final hiddenDir = hasHidden ? rootAlloc.reserve(exportHiddenDir) : '';

  // Map each note's vault folder to its on-disk directory, deduplicating each
  // segment case-insensitively within its parent.
  final dirForNote = <String, String>{};
  final allocators = <String, ExportPathAllocator>{
    '': ExportPathAllocator().._taken.addAll(rootAlloc._taken),
  };
  ExportPathAllocator allocatorFor(String parent) =>
      allocators.putIfAbsent(parent, () => ExportPathAllocator());

  String join(String parent, String name) =>
      parent.isEmpty ? name : '$parent/$name';

  // Every directory path we create, in creation order (parent before child).
  // Uses lowercase keys so an empty folder duplicate never adds a second entry.
  final createdDirs = <String>{};
  final dirOrder = <String>[];

  // Maps parent directory -> exact (case-sensitive, sanitized) segment -> the
  // on-disk segment name already chosen for it. A segment that reappears exactly
  // (same case) must reuse the SAME directory; a segment that differs only in
  // letter case collides case-insensitively and gets a dedup suffix via
  // [ExportPathAllocator], preserving the case of each distinct name.
  final caseMaps = <String, Map<String, String>>{};

  /// Sanitizes and resolves [segments] under the shared per-parent allocators,
  /// mirroring each intermediate directory into [createdDirs]/[dirOrder] so the
  /// empty-folder list and the note-folder list resolve through one allocator.
  String resolveSegments(List<String> segments) {
    var parent = '';
    for (final raw in segments) {
      final cleaned = sanitizeExportSegment(raw);
      final caseMap = caseMaps.putIfAbsent(parent, () => <String, String>{});
      final exact = caseMap[cleaned];
      final String chosen;
      if (exact != null) {
        // Identical segment (same case): share the already chosen directory.
        chosen = exact;
      } else {
        // Reserve the name; case-insensitive collisions get a " (1)" suffix.
        chosen = allocatorFor(parent).reserve(cleaned);
        caseMap[cleaned] = chosen;
      }
      parent = join(parent, chosen);
      final dirKey = parent.toLowerCase();
      if (createdDirs.add(dirKey)) dirOrder.add(parent);
    }
    return parent;
  }

  // Empty vault folders first (their segments claim names before notes that may
  // merely share a prefix), then note folders. Both go through the same
  // allocator so case-only collisions dedup consistently.
  for (final path in folders) {
    resolveSegments(path.split('/').where((s) => s.isNotEmpty).toList());
  }
  for (final note in ordered) {
    if (note.hidden) {
      dirForNote[note.id] = hiddenDir;
      continue;
    }
    dirForNote[note.id] = resolveSegments(
      note.folder.split('/').where((s) => s.isNotEmpty).toList(),
    );
  }

  // Collect every distinct referenced image id in body order; reserve a file
  // name for each available image once, so repeated references share one file.
  final referencedIds = <String>[];
  for (final note in ordered) {
    for (final match in imageReference.allMatches(note.body)) {
      final id = match.group(1)!;
      if (!referencedIds.contains(id)) referencedIds.add(id);
    }
  }

  final imageAlloc = ExportPathAllocator();
  final imageFiles = <ExportImageFile>[];
  final imageFileNameById = <String, String>{};
  var skipped = 0;
  for (final id in referencedIds) {
    final resolved = images[id];
    if (resolved == null) {
      skipped++;
      continue;
    }
    final ext = imageExtensionFor(resolved);
    final base = '${sanitizeExportSegment(id)}.$ext';
    final fileName = imageAlloc.reserve(base);
    imageFileNameById[id] = fileName;
    imageFiles.add(
      ExportImageFile(
        imageId: id,
        fileName: fileName,
        bytes: resolved,
      ),
    );
  }
  if (imageFiles.isNotEmpty) {
    final key = exportImagesDir.toLowerCase();
    if (createdDirs.add(key)) dirOrder.add(exportImagesDir);
  }

  // Rewrite note bodies: replace each available reference with a depth-relative
  // `../_images/<file>` path; unavailable references stay verbatim.
  final files = <ExportNoteFile>[];
  final baseNames = <String>[];
  for (final note in ordered) {
    final dir = dirForNote[note.id] ?? '';
    final depth = dir.isEmpty ? 0 : dir.split('/').length;
    final prefix = depth == 0 ? '' : '../' * depth;
    var body = note.body;
    for (final id in referencedIds) {
      final fileName = imageFileNameById[id];
      if (fileName == null) continue;
      body = body.replaceAll(
        'silique-image:$id',
        '$prefix$exportImagesDir/$fileName',
      );
    }
    // Deduplicate on the base name (without `.md`) so the collision suffix goes
    // before the extension: `Ala.md`, `Ala (1).md`, `Ala (2).md`, …
    final base = sanitizeExportSegment(note.title);
    files.add(
      ExportNoteFile(
        noteId: note.id,
        title: note.title,
        body: body,
        folderPath: note.folder,
        relativeDir: dir,
        fileName: '$base.md',
        hidden: note.hidden,
      ),
    );
    // Remember the resolved base per note, in the same order as `files`.
    baseNames.add(base);
  }

  // Deduplicate the final `.md` names within their own directory (the sanitized
  // title alone is not unique and must be collision-free per directory). The
  // suffix is appended to the base, before `.md`.
  final mdAllocators = <String, ExportPathAllocator>{};
  for (var i = 0; i < files.length; i++) {
    final file = files[i];
    final allocator = mdAllocators.putIfAbsent(
      file.relativeDir,
      () => ExportPathAllocator(),
    );
    final uniqueBase = allocator.reserve(baseNames[i]);
    if (uniqueBase != baseNames[i]) {
      files[i] = ExportNoteFile(
        noteId: file.noteId,
        title: file.title,
        body: file.body,
        folderPath: file.folderPath,
        relativeDir: file.relativeDir,
        fileName: '$uniqueBase.md',
        hidden: file.hidden,
      );
    }
  }

  // The reserved hidden directory is always created when hidden notes exist
  // (every hidden note lands there, so it holds at least one file).
  if (hiddenDir.isNotEmpty) {
    final key = hiddenDir.toLowerCase();
    if (createdDirs.add(key)) dirOrder.add(hiddenDir);
  }

  return VaultExportPlan(
    notes: files,
    images: imageFiles,
    folders: dirOrder,
    hiddenCount: ordered.where((n) => n.hidden).length,
    skippedImageCount: skipped,
  );
}

/// Byte-signature based extension for an image, defaulting to `.bin` so an
/// unrecognized envelope still writes a file rather than guessing a viewer type.
String imageExtensionFor(List<int> bytes) {
  bool starts(List<int> signature) =>
      bytes.length >= signature.length &&
      List.generate(
        signature.length,
        (i) => bytes[i] == signature[i],
      ).every((value) => value);
  if (starts([137, 80, 78, 71, 13, 10, 26, 10])) return 'png';
  if (starts([255, 216, 255])) return 'jpg';
  if (starts([71, 73, 70, 56])) return 'gif';
  if (starts([66, 77])) return 'bmp';
  if (bytes.length >= 12 &&
      ascii.decode(bytes.sublist(0, 4), allowInvalid: true) == 'RIFF' &&
      ascii.decode(bytes.sublist(8, 12), allowInvalid: true) == 'WEBP') {
    return 'webp';
  }
  return 'bin';
}

/// What was exported, used for the summary line.
class VaultExportStats {
  VaultExportStats({
    required this.notes,
    required this.hidden,
    required this.folders,
    required this.images,
    required this.skippedImages,
  });
  final int notes, hidden, folders, images, skippedImages;
}

/// Writes a [plan] to [root] on disk (desktop path).
///
/// Every file is written with `flush: true`; parent directories are created
/// with `recursive: true`. Names come from the sanitizing allocator, and each
/// relative path is validated before touching the filesystem so no note title
/// or folder segment can escape [root] via `..` or an absolute component.
class ExportVaultWriter {
  ExportVaultWriter(this.root);
  final Directory root;

  Future<VaultExportStats> write(VaultExportPlan plan) async {
    var noteCount = 0, hiddenCount = 0, imageCount = 0;

    // Create every planned directory up front — including empty folders that no
    // note or image lands in — so the vault's empty folders survive an export.
    for (final dir in plan.folders) {
      Directory(_safeDirPath(dir)).createSync(recursive: true);
    }

    for (final image in plan.images) {
      final target = File(_safePath(image.relativePath));
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        image.bytes,
        flush: true,
      );
      imageCount++;
    }

    for (final file in plan.notes) {
      final target = File(_safePath(file.relativePath));
      await target.parent.create(recursive: true);
      await target.writeAsString(
        file.content,
        flush: true,
      );
      noteCount++;
      if (file.hidden) hiddenCount++;
    }

    return VaultExportStats(
      notes: noteCount,
      hidden: hiddenCount,
      folders: plan.folders.length,
      images: imageCount,
      skippedImages: plan.skippedImageCount,
    );
  }

  /// Validates a directory path (a sequence of sanitized segments, no `..` or
  /// empty segments) and returns the absolute path under [root]. Directory
  /// creation uses this; file writes use [safeFile] on top of the same guard.
  String _safeDirPath(String relativePath) {
    final segments = relativePath.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw FormatException(
          tr(
            'Nieprawidłowa ścieżka eksportu: $relativePath',
            'Invalid export path: $relativePath',
          ),
        );
      }
      cleaned.add(segment);
    }
    return Directory(
      [root.absolute.path, ...cleaned].join(Platform.pathSeparator),
    ).absolute.path;
  }

  String _safePath(String relativePath) {
    final segments = relativePath.split('/');
    final cleaned = <String>[];
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.' || segment == '..') {
        throw FormatException(
          tr(
            'Nieprawidłowa ścieżka eksportu: $relativePath',
            'Invalid export path: $relativePath',
          ),
        );
      }
      cleaned.add(segment);
    }
    final rootPath = root.absolute.path;
    final target =
        Directory([rootPath, ...cleaned].join(Platform.pathSeparator)).absolute.path;
    if (!(target == rootPath || target.startsWith('$rootPath${Platform.pathSeparator}'))) {
      throw FormatException(
        tr(
          'Ścieżka eksportu wychodzi poza katalog docelowy: $relativePath',
          'The export path escapes the destination folder: $relativePath',
        ),
      );
    }
    return target;
  }
}

/// Builds an in-memory ZIP for mobile sharing.
///
/// Entry paths are relative (no wrapper directory) and use `/` separators.
Uint8List buildVaultExportZip(VaultExportPlan plan) {
  final archive = Archive();
  // Directory entries first (name ending in `/`, zero bytes), so empty folders
  // are preserved in the archive even though they contain no file.
  for (final dir in plan.folders) {
    archive.addFile(ArchiveFile('$dir/', 0, const <int>[]));
  }
  for (final file in plan.notes) {
    final bytes = utf8.encode(file.content);
    archive.addFile(ArchiveFile(file.relativePath, bytes.length, bytes));
  }
  for (final image in plan.images) {
    archive.addFile(
      ArchiveFile(image.relativePath, image.bytes.length, image.bytes),
    );
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A safe base name for the exported ZIP (vault name, sanitized).
String safeVaultZipName(String vaultName) => '${sanitizeExportSegment(vaultName)}.zip';