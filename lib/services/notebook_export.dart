part of 'notebook.dart';

/// Prepares the notes and image bytes for a vault export without
/// re-implementing any cryptography: it reuses [notes], [hiddenNotes] and
/// [imageBytes] from the existing services.
///
/// Returns a value that the pure [VaultExportPlan] builder in
/// `lib/storage/vault_export.dart` consumes.
class ExportVaultData {
  ExportVaultData({
    required this.notes,
    required this.images,
    required this.folders,
  });
  final List<ExportNote> notes;

  /// Resolved image bytes by image id for every reachable reference.
  final Map<String, Uint8List> images;

  /// The vault's full folder list (empty folders included), from
  /// [Notebook.allFolders]; the plan splits and mirrors these segments.
  final List<String> folders;
}

extension NotebookExport on Notebook {
  /// Gathers every non-deleted visible note (and, when [includeHidden], the
  /// decrypted hidden notes) plus the bytes of every reachable image and the
  /// vault's complete folder list (empty folders included).
  ///
  /// This never mutates storage and never throws when an image is unavailable:
  /// references with unresolvable bytes are simply left out of
  /// [ExportVaultData.images] and the plan counts them as skipped.
  Future<ExportVaultData> prepareVaultExport(
    String vaultId, {
    bool includeHidden = false,
  }) async {
    if (!unlocked.containsKey(vaultId)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final visible = (notes[vaultId]?.values ?? const <Note>[])
        .where((n) => !n.deleted && !n.hidden)
        .toList();
    final hidden = includeHidden && hiddenUnlocked
        ? await hiddenNotes(vaultId)
        : const <Note>[];

    final prepared = <ExportNote>[
      for (final note in visible)
        ExportNote(
          id: note.id,
          title: note.title,
          body: note.body,
          folder: note.folder,
        ),
      for (final note in hidden)
        ExportNote(
          id: note.id,
          title: note.title,
          body: note.body,
          folder: note.folder,
          hidden: true,
        ),
    ];

    // Collect every distinct reference across prepared notes.
    final ids = <String>{
      for (final note in prepared)
        ...imageReferencePattern
            .allMatches(note.body)
            .map((m) => m.group(1)!),
    };

    final images = <String, Uint8List>{};
    for (final id in ids) {
      try {
        images[id] = await imageBytes(vaultId, id);
      } catch (_) {
        // Unavailable (e.g. offline) image: leave the reference verbatim.
      }
    }

    return ExportVaultData(
      notes: prepared,
      images: images,
      folders: allFolders(vaultId).toList(),
    );
  }
}