part of 'notebook.dart';

/// The server sees ordinary opaque revisions. The vault key opens a routing
/// envelope only; the independent password key is required for all note fields.
extension _HiddenSync on Notebook {
  static const kind = 'silique.hidden.v1';
  static const configKind = 'silique.hidden.config.v1';
  String _hiddenIndex(String vaultId) => 'hidden-sync:$vaultId';
  String _hiddenConfigs(String vaultId) => 'hidden-config:$vaultId';

  Future<Json?> _hiddenInfo(String vaultId, String noteId) async {
    final data = storage.documents(_hiddenIndex(vaultId))[noteId];
    if (data == null) return null;
    return jsonDecode(
      await crypto.open(
        localKey,
        data,
        'silique:1:hidden-index:$vaultId:$noteId',
      ),
    ) as Json;
  }

  Future<String> _sealHiddenInfo(String vaultId, String noteId, Json info) =>
      crypto.seal(
        localKey,
        jsonEncode(info),
        'silique:1:hidden-index:$vaultId:$noteId',
      );

  Future<Json> _localHiddenConfig() async {
    final salt = await keys.read(Notebook._hiddenSaltSlot);
    final wrap = await keys.read(Notebook._hiddenWrapSlot);
    final check = await keys.read(Notebook._hiddenCheckSlot);
    if (salt == null || wrap == null || check == null) {
      throw StateError(
        tr(
          'Brak konfiguracji hasła ukrytych notatek.',
          'The hidden notes password configuration is missing.',
        ),
      );
    }
    final hash = await Sha256().hash(utf8.encode('$salt|$wrap|$check'));
    return {
      'id': base64UrlEncode(hash.bytes).replaceAll('=', ''),
      'salt': salt,
      'wrap': wrap,
      'check': check,
    };
  }

  Future<Json> _hiddenOuter(Revision r) async => jsonDecode(
    await crypto.openCompat(
      unlocked[r.vaultId]!,
      r.payload,
      r.aad,
      r.legacyAad,
    ),
  ) as Json;

  Future<Json> _hiddenConfig(String vaultId, String id) async => jsonDecode(
    await crypto.open(
      localKey,
      storage.documents(_hiddenConfigs(vaultId))[id]!,
      'silique:1:hidden-config:$vaultId:$id',
    ),
  ) as Json;

  Future<void> _rememberHiddenConfig(String vaultId, Json config) async {
    final id = config['id'] as String;
    if (storage.documents(_hiddenConfigs(vaultId)).containsKey(id)) return;
    storage.putDocument(
      _hiddenConfigs(vaultId),
      id,
      await crypto.seal(
        localKey,
        jsonEncode(config),
        'silique:1:hidden-config:$vaultId:$id',
      ),
    );
  }

  Future<Revision> _hiddenRevision(
    String vaultId,
    String wireId,
    String noteId,
    String sealed,
    Json config,
    List<String> parents, {
    bool retired = false,
  }) async {
    final r = Revision(
      id: _uuid.v4(),
      vaultId: vaultId,
      noteId: wireId,
      parents: parents,
      payload: '',
    );
    final payload = await crypto.seal(
      unlocked[vaultId]!,
      jsonEncode({
        'type': kind,
        'id': noteId,
        'config': config,
        'sealed': sealed,
        if (retired) 'retired': true,
      }),
      r.aad,
    );
    if (utf8.encode(payload).length > 2000000) {
      throw FormatException(
        tr(
          'Ukryta notatka jest zbyt duża do synchronizacji (limit zaszyfrowanej rewizji 2 MB). Zachowano poprzedni zapis.',
          'The hidden note is too large to synchronize (encrypted revision limit: 2 MB). The previous save was preserved.',
        ),
      );
    }
    return Revision(
      id: r.id,
      vaultId: vaultId,
      noteId: wireId,
      parents: parents,
      payload: payload,
    );
  }

  Future<String> _stageHiddenIdentity(
    String vaultId,
    String noteId, {
    bool retiringOrdinary = false,
  }) async {
    final config = _hiddenActiveConfig ?? await _localHiddenConfig();
    await _rememberHiddenConfig(vaultId, config);
    return _sealHiddenInfo(vaultId, noteId, {
      'wire': _uuid.v4(),
      'config': config['id'],
      'unmigrated': true,
      // A local creation never had a remote ordinary identity to purge.
      if (retiringOrdinary) 'ordinaryPurgePending': true,
    });
  }

  /// Upgrade ciphertext written before sync existed, without decrypting or
  /// replacing it.
  /// The index and pending revision commit together, making retries idempotent.
  Future<void> _migrateHidden(Vault vault) async {
    if (_hiddenPasswordSalt != null) {
      final config = await _localHiddenConfig();
      final wireId = await crypto.stableId(
        unlocked[vault.id]!,
        'hidden-config:${config['id']}',
      );
      if (storage.revisions(vault.id, noteId: wireId).isEmpty) {
        final placeholder = Revision(
          id: _uuid.v4(),
          vaultId: vault.id,
          noteId: wireId,
          parents: [],
          payload: '',
        );
        final r = Revision(
          id: placeholder.id,
          vaultId: vault.id,
          noteId: wireId,
          parents: [],
          payload: await crypto.seal(
            unlocked[vault.id]!,
            jsonEncode({'type': configKind, 'config': config}),
            placeholder.aad,
          ),
        );
        await _rememberHiddenConfig(vault.id, config);
        storage.putRevision(r, pending: true);
      }
    }
    for (final entry in storage.documents(_hiddenVault(vault.id)).entries) {
      final info = await _hiddenInfo(vault.id, entry.key);
      if (info != null && info['unmigrated'] != true) continue;
      final config = info == null
          ? await _localHiddenConfig()
          : await _hiddenConfig(vault.id, info['config'] as String);
      final wireId = info?['wire'] as String? ?? _uuid.v4();
      final r = await _hiddenRevision(
        vault.id,
        wireId,
        entry.key,
        entry.value,
        config,
        [],
      );
      final index = await _sealHiddenInfo(vault.id, entry.key, {
        'wire': wireId,
        'config': config['id'],
        if (info?['ordinaryPurgePending'] == true) 'ordinaryPurgePending': true,
      });
      await _rememberHiddenConfig(vault.id, config);
      storage.atomic(() {
        storage.putDocument(_hiddenIndex(vault.id), entry.key, index);
        storage.putRevision(r, pending: true);
      });
    }
  }

  Future<({Revision revision, String index})> _prepareHiddenRevision(
    Note note,
    String sealed,
  ) async {
    final info = await _hiddenInfo(note.vaultId, note.id);
    final config = info == null
        ? (_hiddenActiveConfig ?? await _localHiddenConfig())
        : await _hiddenConfig(note.vaultId, info['config'] as String);
    final wireId = info?['wire'] as String? ?? _uuid.v4();
    // Parent only the version actually projected to the editor. A locked pull
    // can add unseen competing heads; parenting those here would erase them.
    final parents = (info?['applied'] as List? ?? const <String>[])
        .cast<String>();
    final r = await _hiddenRevision(
      note.vaultId,
      wireId,
      note.id,
      sealed,
      config,
      parents,
    );
    await _rememberHiddenConfig(note.vaultId, config);
    return (
      revision: r,
      index: await _sealHiddenInfo(note.vaultId, note.id, {
        'wire': wireId,
        'config': config['id'],
        'applied': [r.id],
        if (info?['ordinaryPurgePending'] == true) 'ordinaryPurgePending': true,
      }),
    );
  }

  Future<void> _acceptHidden(Revision r, Json outer) async {
    final id = outer['id'] as String;
    final config = outer['config'] as Json;
    final configId = config['id'] as String;
    // Do not accept arbitrary KDF parameters from the server. The production
    // CryptoProvider always uses the application's fixed Argon2id cost.
    if (base64Decode(config['salt'] as String).length != 16 ||
        (config['wrap'] as String).isEmpty ||
        (config['check'] as String).isEmpty ||
        (outer['sealed'] as String).isEmpty ||
        id.isEmpty ||
        configId.isEmpty) {
      throw FormatException(
        tr(
          'Nieprawidłowa konfiguracja ukrytej notatki.',
          'Invalid hidden note configuration.',
        ),
      );
    }
    await _rememberHiddenConfig(r.vaultId, config);
    final previous = await _hiddenInfo(r.vaultId, id);
    final index = await _sealHiddenInfo(r.vaultId, id, {
      ...?previous,
      'wire': r.noteId,
      'config': configId,
    });
    storage.putDocument(_hiddenIndex(r.vaultId), id, index);
  }

  Future<List<int>?> _keyForHidden(String vaultId, String noteId) async {
    final info = await _hiddenInfo(vaultId, noteId);
    if (info != null) return _hiddenKeys[info['config']];
    if (_hiddenPasswordSalt == null) return null;
    return _hiddenKeys[(await _localHiddenConfig())['id']];
  }

  Future<Map<String, ({List<int> key, Json config})>> _unlockPortableHidden(
    String password,
  ) async {
    final matched = <String, ({List<int> key, Json config})>{};
    for (final vault in vaults.where((v) => unlocked.containsKey(v.id))) {
      for (final id in storage.documents(_hiddenConfigs(vault.id)).keys) {
        final config = await _hiddenConfig(vault.id, id);
        try {
          final wrapping = await crypto.passwordKey(
            password,
            base64Decode(config['salt'] as String),
          );
          final key = base64Decode(
            await crypto.open(
              wrapping,
              config['wrap'] as String,
              'silique:1:hidden-key',
            ),
          );
          await crypto.open(
            key,
            config['check'] as String,
            'silique:1:hidden-check',
          );
          matched[id] = (key: key, config: config);
        } on SecretBoxAuthenticationError {
          // Independently configured devices retain separate password domains.
        }
      }
    }
    return matched;
  }

  Future<void> _acceptPurge(String vaultId, String wireId) async {
    for (final id in storage.documents(_hiddenIndex(vaultId)).keys) {
      final info = await _hiddenInfo(vaultId, id);
      if (info?['wire'] != wireId) continue;
      storage.atomic(() {
        // Keep the retired local identity even when an imported note had no
        // marker. A queued ordinary edit cannot resurrect deleted plaintext.
        storage.putDocument(_hiddenRetiredVault(vaultId), id, 'local');
        storage.removeDocument(_hiddenVault(vaultId), id);
        storage.removeDocument(_hiddenIndex(vaultId), id);
      });
    }
    await _eraseNote(vaultId, wireId);
  }

  Future<void> _purgeHidden(Note note) async {
    if (!note.deleted || !hiddenUnlocked) {
      throw StateError(
        tr(
          'Najpierw usuń i odblokuj ukrytą notatkę.',
          'Delete and unlock the hidden note first.',
        ),
      );
    }
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    if (vault.owner != null) {
      if (!vault.syncEnabled || session?.owner != vault.owner || api == null) {
        throw StateError(
          tr(
            'Połącz konto właściciela i włącz synchronizację.',
            'Connect the owner\'s account and enable synchronization.',
          ),
        );
      }
      await sync();
    }
    await serialized(() async {
      final info = await _hiddenInfo(vault.id, note.id);
      if (info == null && vault.owner == null) {
        storage.removeDocument(_hiddenVault(vault.id), note.id);
        _localChanges.add(null);
        return;
      }
      if (info == null) {
        throw StateError(
          tr('Nie znaleziono ukrytej notatki.', 'Hidden note not found.'),
        );
      }
      final wireId = info['wire'] as String;
      if (vault.owner != null) {
        final response = await api!.request(
          'DELETE',
          '/v1/vaults/${vault.id}/notes/$wireId',
        );
        if (response['purged'] != true) {
          throw FormatException(
            tr(
              'Brak potwierdzenia usunięcia.',
              'Deletion was not acknowledged.',
            ),
          );
        }
      }
      await _acceptPurge(vault.id, wireId);
      _localChanges.add(null);
    });
  }

  Future<void> _projectHidden(Vault vault, String wireId) async {
    final branches = heads(vault.id, wireId);
    if (branches.isEmpty) return;
    final outer = await _hiddenOuter(branches.first);
    final id = outer['id'] as String;
    final info = await _hiddenInfo(vault.id, id);
    final branchIds = branches.map((r) => r.id).toList();
    if (jsonEncode(info?['applied']) == jsonEncode(branchIds)) return;
    Future<void> applied(List<String> ids) async {
      storage.putDocument(
        _hiddenIndex(vault.id),
        id,
        await _sealHiddenInfo(vault.id, id, {...?info, 'applied': ids}),
      );
    }

    for (final branch in branches) {
      if ((await _hiddenOuter(branch))['retired'] == true) {
        storage.removeDocument(_hiddenVault(vault.id), id);
        await applied(branchIds);
        return;
      }
    }
    // A single head can be cached while locked, without decrypting any fields.
    if (branches.length == 1) {
      storage.putDocument(
        _hiddenVault(vault.id),
        id,
        outer['sealed'] as String,
      );
      await applied(branchIds);
      return;
    }
    if (!hiddenUnlocked) return;
    final key = await _keyForHidden(vault.id, id);
    if (key == null) return;
    final documents = <Note>[];
    for (final r in branches) {
      final envelope = await _hiddenOuter(r);
      final note = Note.fromJson(
        jsonDecode(
          await crypto.open(
            key,
            envelope['sealed'] as String,
            'silique:1:hidden:${vault.id}:$id',
          ),
        ) as Json,
      );
      if (note.id != id || note.vaultId != vault.id || !note.hidden) {
        throw FormatException(
          tr(
            'Niezgodna tożsamość ukrytej notatki.',
            'Hidden note identity mismatch.',
          ),
        );
      }
      documents.add(note);
    }
    final result = documents.firstWhere(
      (n) => !n.deleted,
      orElse: () => documents.first,
    );
    final config = outer['config'] as Json;
    final distinct = <Note>[result];
    for (var i = 0; i < documents.length; i++) {
      final n = documents[i];
      // Like ordinary notes, an edit beats a concurrent soft deletion.
      if (n.deleted ||
          distinct.any((other) => Notebook._sameContent(other, n))) {
        continue;
      }
      distinct.add(n);
      final copyId = await crypto.stableId(
        key,
        'hidden-conflict:$wireId:${branches[i].id}',
      );
      if (storage.documents(_hiddenVault(vault.id)).containsKey(copyId)) {
        continue;
      }
      final copy = Note(
        id: copyId,
        vaultId: vault.id,
        // Keep deterministic copy content compatible with legacy clients;
        // interface language must never affect this persisted title.
        title: '${n.title} (kopia konfliktowa)',
        body: n.body,
        folder: n.folder,
        createdAt: n.createdAt,
        updatedAt: n.updatedAt,
        favorite: n.favorite,
        tags: n.tags,
        journalDate: n.journalDate,
        hidden: true,
        conflict: true,
      );
      final sealed = await crypto.seal(
        key,
        jsonEncode(copy.toJson()),
        'silique:1:hidden:${vault.id}:$copyId',
      );
      final copyWire = await crypto.stableId(
        key,
        'hidden-conflict-wire:$copyId',
      );
      final r = await _hiddenRevision(
        vault.id,
        copyWire,
        copyId,
        sealed,
        config,
        [],
      );
      final index = await _sealHiddenInfo(vault.id, copyId, {
        'wire': copyWire,
        'config': config['id'],
      });
      storage.atomic(() {
        storage.putDocument(_hiddenVault(vault.id), copyId, sealed);
        storage.putDocument(_hiddenIndex(vault.id), copyId, index);
        storage.putDocument(_hiddenRetiredVault(vault.id), copyId, 'local');
        storage.putRevision(r, pending: true);
      });
    }
    final sealed = await crypto.seal(
      key,
      jsonEncode(result.toJson()),
      'silique:1:hidden:${vault.id}:$id',
    );
    storage.putDocument(_hiddenVault(vault.id), id, sealed);
    if (documents.every((n) => Notebook._sameContent(n, result))) {
      await applied(branchIds);
      return;
    }
    final resolution = await _hiddenRevision(
      vault.id,
      wireId,
      id,
      sealed,
      config,
      branches.map((r) => r.id).toList(),
    );
    storage.putRevision(resolution, pending: true);
    await applied([resolution.id]);
    _localChanges.add(null);
  }

  Future<void> _refreshHidden(String vaultId) async {
    final vault = vaults.firstWhere((v) => v.id == vaultId);
    final all = storage.revisions(vaultId);
    for (final wireId in all.map((r) => r.noteId).toSet()) {
      if ((await _hiddenOuter(
            all.firstWhere((r) => r.noteId == wireId),
          ))['type'] ==
          kind) {
        await _projectHidden(vault, wireId);
      }
    }
  }
}
