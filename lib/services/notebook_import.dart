part of 'notebook.dart';

class VaultImportResult {
  VaultImportResult(this.notes, this.folderCount, this.imageCount);
  final List<Note> notes;
  final int folderCount, imageCount;
}

extension NotebookImport on Notebook {
  /// Prepare every encrypted document, revision and image before committing.
  /// A malformed file, locked vault or failed transaction leaves no partial
  /// notes/folders/outbox entries. Sources are only read, never moved or edited.
  Future<VaultImportResult> importVault(
    String vaultId,
    VaultImportPlan plan, {
    String destination = '',
    void Function(int done, int total)? onProgress,
  }) => serialized(() async {
    final key = unlocked[vaultId];
    if (key == null) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final vault = vaults.firstWhere((v) => v.id == vaultId);
    if (destination.isNotEmpty &&
        normalizeFolderPath(destination) != destination) {
      throw FormatException(
        folderPathError(destination) ??
            tr('Nieprawidłowy folder docelowy.', 'Invalid destination folder.'),
      );
    }
    final folders = <String>{...allFolders(vaultId)};
    final importedFolders = <String>{
      if (destination.isNotEmpty) destination,
      for (final folder in plan.folders) joinFolderPath(destination, folder),
      for (final note in plan.notes)
        if (joinFolderPath(destination, note.folder).isNotEmpty)
          joinFolderPath(destination, note.folder),
    };
    for (final folder in importedFolders.toList()) {
      importedFolders.addAll(folderAncestors(folder));
    }
    for (final folder in importedFolders) {
      if (normalizeFolderPath(folder) != folder) {
        throw FormatException(
          tr(
            'Folder „$folder”: ${folderPathError(folder) ?? 'nieprawidłowa nazwa'}. Wybierz krótszy folder docelowy.',
            'Folder “$folder”: ${folderPathError(folder) ?? 'invalid name'}. Choose a shorter destination folder.',
          ),
        );
      }
      if (folders.any(
        (f) => f != folder && f.toLowerCase() == folder.toLowerCase(),
      )) {
        throw FormatException(
          tr(
            'Folder „$folder” różni się tylko wielkością liter od istniejącego. Wybierz osobny folder importu.',
            'Folder “$folder” differs from an existing folder only in letter case. Choose a separate import folder.',
          ),
        );
      }
      folders.add(folder);
    }
    final ids = {for (final note in plan.notes) note.path: _uuid.v4()};
    final prepared = <({Note note, Revision revision, String document})>[];
    final images = <_PreparedImage>[];
    var totalBytes = 0;
    onProgress?.call(0, plan.notes.length);
    for (final imported in plan.notes) {
      final id = ids[imported.path]!;
      final imageLinks = <String, String>{};
      // A single document import preserves literal Markdown, including missing
      // local images. Only selecting a folder grants attachment rewriting scope.
      final body = plan.source is MarkdownFileImportSource
          ? imported.body
          : await rewriteImportedBody(imported.body, (
              target,
              label,
              image,
            ) async {
              if (Uri.tryParse(target)?.hasScheme == true ||
                  target.startsWith('//') ||
                  target.startsWith('#')) {
                return null;
              }
              final path = resolveImportLink(imported.path, target, plan.files);
              if (path == null) {
                if (image) {
                  throw FormatException(
                    tr(
                      'Brak zdjęcia „$target” w wybranym folderze (${imported.path}).',
                      'Image “$target” is missing from the selected folder (${imported.path}).',
                    ),
                  );
                }
                return null;
              }
              final escaped = label
                  .replaceAll('\\', '\\\\')
                  .replaceAll('[', '\\[')
                  .replaceAll(']', '\\]');
              if (image && !ids.containsKey(path)) {
                final mime = importImageMime(path);
                // Obsidian uses embeds for CSV, PDF, Bases and other attachments too.
                // These files are listed as skipped in the preview; keep the original
                // reference without reading them or aborting the note import.
                if (mime == null) return null;
                var reference = imageLinks[path];
                if (reference == null) {
                  final bytes = await plan.source.read(
                    path,
                    limit: importByteLimit - totalBytes,
                  );
                  totalBytes += bytes.length;
                  final attachment = await _prepareImage(
                    vaultId,
                    id,
                    bytes,
                    mime,
                  );
                  images.add(attachment);
                  reference = 'silique-image:${attachment.id}';
                  imageLinks[path] = reference;
                }
                return '![$escaped]($reference)';
              }
              final noteId = ids[path];
              if (noteId == null) return null;
              return '[$escaped](silique-note:$noteId)';
            });
      totalBytes += utf8.encode(body).length;
      if (totalBytes > importByteLimit) {
        throw FormatException(
          tr(
            'Import przekracza 256 MB. Podziel go na części.',
            'The import exceeds 256 MB. Split it into smaller parts.',
          ),
        );
      }
      final note = Note(
        id: id,
        vaultId: vaultId,
        title: imported.title,
        body: body,
        folder: joinFolderPath(destination, imported.folder),
        updatedAt: DateTime.now().toUtc(),
      );
      if (utf8.encode(jsonEncode(note.toJson())).length > 1000000) {
        throw FormatException(
          tr(
            'Notatka „${imported.path}” przekracza limit 1 MB.',
            'Note “${imported.path}” exceeds the 1 MB limit.',
          ),
        );
      }
      final revision = await _makeRevision(note, []);
      final plain = jsonEncode({
        ...note.toJson(),
        '_heads': [revision.id],
      });
      final document = vault.protected
          ? await crypto.seal(key, plain, 'silique:2:local-note:$vaultId:$id')
          : plain;
      prepared.add((note: note, revision: revision, document: document));
      onProgress?.call(prepared.length, plan.notes.length);
    }
    final metadata = <String, dynamic>{
      ...?_meta[vaultId],
      'name': _names[vaultId] ?? vault.name,
      'folders': folders.toList()..sort(),
    };
    final updated = Vault.fromJson(vault.toJson());
    updated.metadata = await crypto.seal(
      key,
      jsonEncode(metadata),
      'silique:2:vault-meta:$vaultId',
    );
    if (updated.folderBase.isEmpty && updated.syncEnabled) {
      // Normal sync uses the local tree as its fallback for pre-base clients.
      // Snapshot that tree before this import so new additions remain a delta.
      await _setFolderBase(updated, allFolders(vaultId).toList());
    }
    if (updated.metadata.length > 1000000) {
      throw FormatException(
        tr(
          'Drzewo folderów jest zbyt duże. Podziel import na części.',
          'The folder tree is too large. Split the import into smaller parts.',
        ),
      );
    }
    // Keep the last confirmed folder base intact. The next normal sync merges
    // these offline additions with the server instead of replacing its tree.
    if (!identical(unlocked[vaultId], key)) {
      throw StateError(
        tr(
          'Vault został zablokowany. Import anulowano.',
          'The vault has been locked. Import cancelled.',
        ),
      );
    }
    storage.atomic(() {
      storage.putVault(updated);
      for (final item in prepared) {
        storage.putDocument(vaultId, item.note.id, item.document);
        storage.putRevision(item.revision, pending: true);
      }
      for (final image in images) {
        _storePreparedImage(vaultId, image);
      }
    });
    _meta[vaultId] = metadata;
    for (final item in prepared) {
      notes.putIfAbsent(vaultId, () => {})[item.note.id] = item.note;
      _knownHeads['$vaultId:${item.note.id}'] = [item.revision.id];
    }
    for (final item in prepared) {
      await _mirror(item.note);
    }
    return VaultImportResult(
      prepared.map((p) => p.note).toList(),
      importedFolders.length,
      images.length,
    );
  });
}
