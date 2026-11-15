part of 'notebook.dart';

enum _NoteSyncType { ordinary, hidden, hiddenConfig }

/// The source-of-truth reset: retires every ordinary note's heads behind a
/// single new revision whose content is this device's local document, so the
/// server (a dumb immutable store) ends with exactly one head per note. Hidden
/// notes are never touched; losing versions are preserved as conflict copies
/// when requested.
extension NotebookReset on Notebook {
  /// Cap on losing-version copies per note, so a single note with many
  /// competing heads cannot explode into an unbounded number of copies.
  static const _maxLosingCopiesPerNote = 5;

  /// Cap on parents per revision, matching the server contract. Each link of a
  /// retire chain cites up to `_maxParents - 1` remaining heads plus the
  /// previous link, so a chain never exceeds the server limit.
  static const _maxParents = 32;

  /// Bounded number of push passes, mirroring `_forceFlushPending`. A reset can
  /// produce more than one batch (chain links + copies), but must never loop
  /// forever on a server that keeps rejecting.
  static const _maxPushPasses = 200;

  Future<VaultResetReport> _resetToLocalSourceOfTruth(
    String vaultId, {
    required bool keepLosingCopies,
  }) async {
    if (_updatePrepared && !_insideOperation) {
      return const VaultResetReport(
        notesRewritten: 0,
        deletionsWritten: 0,
        copiesKept: 0,
        headsMerged: 0,
        remainingDiverged: 0,
        hiddenSkipped: 0,
      );
    }
    _requireLiveVault(vaultId);
    final vault = vaults.firstWhere(
      (v) => v.id == vaultId,
      orElse: () => throw StateError(
        tr('Nieznany vault.', 'Unknown vault.'),
      ),
    );
    if (!unlocked.containsKey(vaultId)) {
      throw StateError(tr('Najpierw odblokuj vault.', 'Unlock the vault first.'));
    }
    if (!vault.syncEnabled) {
      throw StateError(
        tr(
          'Włącz synchronizację, aby ustawić źródło prawdy.',
          'Enable synchronization to set the source of truth.',
        ),
      );
    }
    if (!_ownerIsCurrent(vault.owner)) {
      throw StateError(
        tr(
          'Połącz konto właściciela vaulta.',
          'Connect the vault owner\'s account.',
        ),
      );
    }
    if (vaultDeletionPending(vaultId) || storage.isVaultDeleted(vaultId)) {
      throw StateError(
        tr(
          'Vault usunięto lub oczekuje na dokończenie usuwania.',
          'The vault has been deleted or is awaiting deletion.',
        ),
      );
    }
    if (_syncing || _hiddenMoving) {
      throw StateError(
        tr(
          'Synchronizacja jest w toku — poczekaj, aż się zakończy.',
          'A sync is in progress — wait for it to finish.',
        ),
      );
    }
    final client = api;
    if (client == null) {
      throw StateError(
        tr(
          'Brak połączenia z serwerem. Zaloguj się, aby kontynuować.',
          'Not connected to a server. Sign in to continue.',
        ),
      );
    }

    _syncing = true;
    try {
      // 1. Full pull from cursor 0 so every reset revision can cite heads the
      // server already has. No reconcile: we must not run the three-way merge
      // on top of the divergence we are about to resolve.
      await _resetFullPull(client, vault, reconcile: false);

      // 2+3. Snapshot, build the reset/copy revisions, then retire the stuck
      // queue — all under one serialized critical section so a concurrent edit
      // can never interleave between reading heads and writing the reset.
      final report = await serialized(
        () => _buildAndWriteReset(vault, keepLosingCopies: keepLosingCopies),
      );

      // 4. Push the reset revisions through the normal image-filtering path.
      for (var i = 0; i < _maxPushPasses; i++) {
        final before = storage.pendingCount(vaultId);
        final hadBatch = storage.batch(vaultId) != null;
        if (before == 0 && !hadBatch) break;
        await _push(vault);
        final after = storage.pendingCount(vaultId);
        if (after >= before && storage.batch(vaultId) == null) break;
      }

      // 5. Final full pull + reconcile, then report the remaining divergence.
      await _resetFullPull(client, vault, reconcile: true);
      final remaining = await serialized(() => _ordinaryDivergedCount(vaultId));

      return VaultResetReport(
        notesRewritten: report.notesRewritten,
        deletionsWritten: report.deletionsWritten,
        copiesKept: report.copiesKept,
        headsMerged: report.headsMerged,
        remainingDiverged: remaining,
        hiddenSkipped: report.hiddenSkipped,
      );
    } finally {
      _syncing = false;
    }
  }

  /// Replays the whole changelog of [vault] from cursor 0, optionally ending
  /// with a reconcile. Mirrors `_forceFullPull`'s per-page loop without merging:
  /// the reset snapshots heads *before* the three-way merge would collapse them.
  Future<void> _resetFullPull(
    SiliqueApi client,
    Vault vault, {
    required bool reconcile,
  }) async {
    storage.setCursor(vault.id, 0);
    var more = true;
    while (more) {
      final page = await client.request(
        'GET',
        '/v1/vaults/${vault.id}/changes?cursor=${storage.cursor(vault.id)}',
      );
      await serialized(() async {
        for (final noteId in (page['purged'] as List? ?? const [])) {
          await _acceptPurge(vault.id, noteId as String);
        }
        final incoming = <Revision>[];
        for (final item in page['revisions'] as List) {
          final j = item as Json;
          final r = Revision(
            id: j['id'] as String,
            vaultId: vault.id,
            noteId: j['noteId'] as String,
            parents: (j['parents'] as List).cast<String>(),
            payload: j['payload'] as String,
            seq: j['seq'] as int,
          );
          if (_hiddenIdentity(vault.id, r.noteId)) continue;
          final decoded = await _hiddenOuter(r);
          if (decoded['type'] == _HiddenSync.configKind) {
            await _rememberHiddenConfig(vault.id, decoded['config'] as Json);
            incoming.add(r);
            continue;
          }
          if (decoded['type'] == _HiddenSync.kind) {
            await _acceptHidden(r, decoded);
            incoming.add(r);
            continue;
          }
          final plain = Note.fromJson(decoded);
          if (plain.id != r.noteId || plain.vaultId != vault.id) {
            throw FormatException(
              tr(
                'Serwer zwrócił niezgodną tożsamość notatki.',
                'The server returned a mismatched note identity.',
              ),
            );
          }
          incoming.add(r);
        }
        storage.atomic(() {
          for (final r in incoming) {
            storage.putRevision(r);
          }
          storage.setCursor(vault.id, page['cursor'] as int);
        });
      });
      more = page['hasMore'] as bool;
    }
    if (reconcile) {
      await serialized(() => _reconcile(vault));
      // The final pull can bring images this device never cached; without this
      // the freshly converged notes would show placeholders until a later pass.
      await _cacheImages(vault);
    }
  }

  /// The snapshot + build + atomic-retire critical section. Returns the counts
  /// gathered before the final pull recalculates divergence.
  Future<({int notesRewritten, int deletionsWritten, int copiesKept, int headsMerged, int hiddenSkipped})> _buildAndWriteReset(
    Vault vault, {
    required bool keepLosingCopies,
  }) async {
    final all = storage.revisions(vault.id);
    final noteIds = <String>{
      ...all.map((r) => r.noteId),
      ...storage.documents(vault.id).keys,
      ...?notes[vault.id]?.keys,
    };

    var notesRewritten = 0;
    var deletionsWritten = 0;
    var copiesKept = 0;
    var headsMerged = 0;
    var hiddenSkipped = 0;

    // Revisions to write, in DAG (parent-before-child) order per note.
    final resetRevisions = <Revision>[];
    // Losing-version copies, each with its document to materialise.
    final copyWrites = <({Revision revision, Note note})>[];
    // Local documents to update to their new single head (noteId -> head ids).
    final documentHeads = <String, List<String>>{};

    for (final noteId in noteIds) {
      final type = await _noteSyncType(vault, noteId);
      if (type == _NoteSyncType.hiddenConfig) continue;
      if (type == _NoteSyncType.hidden) {
        hiddenSkipped++;
        continue;
      }

      // Server-known heads (seq > 0): these exist on the server and may be
      // cited as parents. Local-only (seq == 0) pending heads are superseded by
      // the chosen content and retired with the stuck queue.
      final serverHeads = _serverHeads(vault, noteId);
      if (serverHeads.isEmpty) continue; // purged or never written: nothing to reset.

      // The chosen content: the local document when present, otherwise a
      // deletion that wins over the remote-only heads.
      final localNote = notes[vault.id]?[noteId] ??
          await _localDocument(vault, noteId);
      final chosen = localNote ??
          Note(
            id: noteId,
            vaultId: vault.id,
            title: tr('Bez tytułu', 'Untitled'),
            body: '',
            updatedAt: DateTime.now().toUtc(),
            deleted: true,
          );

      final isDeletion = chosen.deleted || localNote == null;

      // Retire the heads. >32 heads become a deterministic chain.
      final chain = await _retireChain(vault, chosen, serverHeads);
      resetRevisions.addAll(chain.revisions);
      headsMerged += serverHeads.length;
      if (isDeletion) {
        deletionsWritten++;
      } else {
        notesRewritten++;
      }
      documentHeads[noteId] = [chain.revisions.last.id];

      // Preserve losing versions as deterministic conflict copies.
      if (keepLosingCopies) {
        copiesKept += await _collectLosingCopies(
          vault,
          noteId,
          chosen,
          serverHeads,
          copyWrites,
        );
      }
    }

    // New revisions first, then acknowledge only the superseded pending
    // revisions and drop the durable batch — atomically, so the vault is never
    // left with neither the old nor the new revisions.
    //
    // The acknowledge must not be a blanket `pendingIds(vault.id)`: that set also
    // contains (a) the pending revision of a local-only ordinary note (seq == 0,
    // never pushed) that received no reset revision and would be silently
    // stranded off-server, and (b) hidden-note / hidden-config revisions, which
    // the reset explicitly does not touch. Only ordinary notes that actually got
    // a reset revision (those in `documentHeads`) have their old pending queue
    // superseded; every other pending revision keeps `pending=1` and continues to
    // sync through the normal channel.
    final oldPendingIds = storage.pendingIds(vault.id);
    final noteIdById = {for (final r in all) r.id: r.noteId};
    final supersededIds = oldPendingIds
        .where((id) => documentHeads.containsKey(noteIdById[id]))
        .toList();
    storage.atomic(() {
      for (final r in resetRevisions) {
        storage.putRevision(r, pending: true);
      }
      for (final c in copyWrites) {
        storage.putRevision(c.revision, pending: true);
      }
      storage.acknowledge(vault.id, supersededIds);
    });

    // Materialise the copies and point each rewritten note at its new head.
    for (final c in copyWrites) {
      await _document(c.note, [c.revision.id]);
      await _mirror(c.note);
    }
    for (final entry in documentHeads.entries) {
      final note = notes[vault.id]?[entry.key] ??
          await _localDocument(vault, entry.key);
      if (note != null) {
        await _document(note, entry.value);
        await _mirror(note);
      }
    }

    return (
      notesRewritten: notesRewritten,
      deletionsWritten: deletionsWritten,
      copiesKept: copiesKept,
      headsMerged: headsMerged,
      hiddenSkipped: hiddenSkipped,
    );
  }

  /// Decodes [noteId]'s local document from storage into a [Note], or null when
  /// no document exists (remote-only / purged).
  Future<Note?> _localDocument(Vault vault, String noteId) async {
    final raw = storage.documents(vault.id)[noteId];
    if (raw == null) return null;
    final json = vault.protected
        ? jsonDecode(
            await crypto.open(
              unlocked[vault.id]!,
              raw,
              'silique:2:local-note:${vault.id}:$noteId',
            ),
          )
        : jsonDecode(raw);
    return Note.fromJson(json as Json);
  }

  /// Builds the retire chain for [note]: a single revision when there are at
  /// most 32 heads, otherwise a sequence where each link cites up to 31
  /// remaining heads plus the previous link. Every link carries [chosen]'s
  /// content, and the chain terminates with exactly one head.
  Future<({List<Revision> revisions})> _retireChain(
    Vault vault,
    Note chosen,
    List<Revision> serverHeads,
  ) async {
    if (serverHeads.length <= _maxParents) {
      final rev = await _makeRevision(
        chosen,
        serverHeads.map((r) => r.id).toList(),
      );
      return (revisions: [rev]);
    }
    final revisions = <Revision>[];
    var previousId = '';
    var i = 0;
    while (i < serverHeads.length) {
      final end = (i + _maxParents - 1).clamp(0, serverHeads.length);
      final parents = <String>[
        for (final r in serverHeads.sublist(i, end))
          r.id,
        if (previousId.isNotEmpty) previousId,
      ];
      final rev = await _makeRevision(chosen, parents);
      revisions.add(rev);
      previousId = rev.id;
      i = end;
    }
    return (revisions: revisions);
  }

  /// Creates losing-version copies for every distinct server-head content that
  /// differs from [chosen], capped at `_maxLosingCopiesPerNote` per note. The
  /// copy id is deterministic (`crypto.stableId`), so a re-run is idempotent and
  /// every device derives the same id. Appends to [copyWrites] and returns how
  /// many new copies were added.
  Future<int> _collectLosingCopies(
    Vault vault,
    String noteId,
    Note chosen,
    List<Revision> serverHeads,
    List<({Revision revision, Note note})> copyWrites,
  ) async {
    var added = 0;
    final seen = <String>{};
    for (final head in serverHeads) {
      if (added >= _maxLosingCopiesPerNote) break;
      final headNote = await _decode(head);
      // A head that already matches the chosen content (including a concurrent
      // identical edit) is not "losing".
      if (Notebook._sameContent(headNote, chosen)) continue;
      final fingerprint = jsonEncode(headNote.toJson()..remove('updatedAt'));
      if (!seen.add(fingerprint)) continue;
      final copyId = await crypto.stableId(
        unlocked[vault.id]!,
        'pre-reset:$noteId:${head.id}',
      );
      if (notes[vault.id]?.containsKey(copyId) == true) continue;
      if (storage.documents(vault.id).containsKey(copyId)) continue;
      final copy = Note(
        id: copyId,
        vaultId: vault.id,
        // Deterministic content, independent of the interface language.
        title: '${headNote.title} (kopia przed scaleniem)',
        body: headNote.body,
        folder: headNote.folder,
        createdAt: headNote.createdAt,
        updatedAt: headNote.updatedAt,
        favorite: headNote.favorite,
        tags: headNote.tags,
        journalDate: headNote.journalDate,
        conflict: true,
      );
      final rev = await _makeRevision(copy, []);
      copyWrites.add((revision: rev, note: copy));
      added++;
    }
    return added;
  }

  /// Classifies how the reset should treat [noteId]: an ordinary note, a hidden
  /// note (skip and report), or a hidden config envelope (skip silently).
  Future<_NoteSyncType> _noteSyncType(Vault vault, String noteId) async {
    final revisions = storage.revisions(vault.id, noteId: noteId);
    if (revisions.isNotEmpty) {
      final outer = await _hiddenOuter(revisions.first);
      if (outer['type'] == _HiddenSync.configKind) return _NoteSyncType.hiddenConfig;
      if (outer['type'] == _HiddenSync.kind) return _NoteSyncType.hidden;
    }
    if (_hiddenIdentity(vault.id, noteId)) return _NoteSyncType.hidden;
    return _NoteSyncType.ordinary;
  }

  /// Counts ordinary notes (excluding hidden envelopes and identities) that
  /// still have more than one head, so the final success criterion ("exactly
  /// zero") is measured only over the notes the reset actually governs.
  Future<int> _ordinaryDivergedCount(String vaultId) async {
    var count = 0;
    final all = storage.revisions(vaultId);
    for (final noteId in all.map((r) => r.noteId).toSet()) {
      final vault = vaults.firstWhere(
        (v) => v.id == vaultId,
        orElse: () => throw StateError(tr('Nieznany vault.', 'Unknown vault.')),
      );
      if (await _noteSyncType(vault, noteId) != _NoteSyncType.ordinary) {
        continue;
      }
      if (_serverHeads(vault, noteId).length > 1) count++;
    }
    return count;
  }

  /// Heads of [noteId] among only the server-known revisions (`seq > 0`), in
  /// deterministic (id-sorted) order. These are the heads the server holds and
  /// therefore the only parents a reset revision may cite without a 409. A
  /// full pull has just assigned `seq > 0` to every served revision, so this is
  /// exactly "the heads the server already has".
  List<Revision> _serverHeads(Vault vault, String noteId) {
    final known = storage.revisions(vault.id, noteId: noteId).where((r) => r.seq > 0).toList();
    final parentIds = known.expand((r) => r.parents).toSet();
    return known.where((r) => !parentIds.contains(r.id)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }
}