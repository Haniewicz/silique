import '../l10n/strings.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart'
    show SecretBoxAuthenticationError, Sha256;

import 'package:uuid/uuid.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/native_storage.dart';
import '../storage/vault_import.dart';

import '../core/contracts.dart';
import '../core/server_trust.dart';
import '../core/credential_mode.dart';
import '../core/models.dart';
import '../core/merge.dart';
import '../core/workspace.dart';
import 'api.dart';

part 'notebook_images.dart';
part 'notebook_import.dart';
part 'notebook_hidden_sync.dart';
part 'notebook_vault_deletion.dart';

class _NotebookOperation {
  bool active = true;
}

class _NotebookKeys implements KeyStore {
  _NotebookKeys(this.notebook, this.delegate);
  final Notebook notebook;
  final KeyStore delegate;
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> write(String key, String value) => notebook._operation(
    () => delegate.write(key, value),
    failureKey: ('credential', key),
  );
  @override
  Future<void> delete(String key) => notebook._operation(
    () => delegate.delete(key),
    failureKey: ('credential', key),
  );
}

class _NotebookCredentialKeys extends _NotebookKeys
    implements CredentialModeControl {
  _NotebookCredentialKeys(super.notebook, super.delegate, this.control);
  final CredentialModeControl control;
  @override
  CredentialMode get mode => control.mode;
  @override
  bool get cleanupPending => control.cleanupPending;
  @override
  Future<void> changeMode(CredentialMode mode) => notebook._operation(
    () => control.changeMode(mode),
    failureKey: 'credential-mode',
  );
  @override
  Future<void> retryCleanup() =>
      notebook._operation(control.retryCleanup, failureKey: 'credential-mode');
}

/// Sentinel for `_writeMeta.defaultFolderColor`: distinguishes "leave the
/// stored value unchanged" (the default) from the explicit `null` ("no default
/// folder color"). `defaultNoteColor` needs no sentinel — it always has a
/// concrete value and is never cleared.
const Object _keepDefaultFolderColor = Object();

class Notebook {
  Notebook({
    required this.storage,
    required KeyStore keys,
    required this.crypto,
    ServerTrust? trust,
  }) : trust = trust ?? ServerTrust(store: InMemoryTrustStore()) {
    this.keys = keys is CredentialModeControl
        ? _NotebookCredentialKeys(this, keys, keys as CredentialModeControl)
        : _NotebookKeys(this, keys);
  }
  final ServerTrust trust;
  NoteStorage storage;
  List<Json>? devices;
  String? _lastVaultId;
  String? get lastVaultId => vaults.any((v) => v.id == _lastVaultId)
      ? _lastVaultId
      : vaults.firstOrNull?.id;

  Future<void> rememberVault(String id) => serialized(() async {
    if (!vaults.any((v) => v.id == id)) {
      throw StateError(
        tr(
          'Ten vault nie jest już dostępny.',
          'This vault is no longer available.',
        ),
      );
    }
    if (_lastVaultId == id) return;
    await keys.write('nova.lastVault', id);
    _lastVaultId = id;
  });
  String get dataLocation => storage is NativeStorage
      ? (storage as NativeStorage).root
      : tr('Magazyn aplikacji', 'App storage');
  late final KeyStore keys;
  final CryptoProvider crypto;
  final _uuid = const Uuid();
  late List<int> localKey;
  late String deviceId;
  late Json deviceIdentity;
  Session? session;
  SiliqueApi? api;
  List<int>? accountKey;
  final unlocked = <String, List<int>>{};
  final notes = <String, Map<String, Note>>{};
  final _knownHeads = <String, List<String>>{};
  final _names = <String, String>{};
  final _meta = <String, Json>{};
  Future<void> _tail = Future.value();
  bool _updatePrepared = false;
  // The serialization tail must stay usable after an error, but a failed
  // accepted write must never be mistaken for a save-safe update handoff.
  final _updateWriteFailures = <Object, Object>{};
  final _pendingOperations = <Future<void>>{};
  final _operationZoneKey = Object();

  bool get _insideOperation =>
      (Zone.current[_operationZoneKey] as _NotebookOperation?)?.active ?? false;

  // Unlike the SQL queue, this tracks an operation's entire async lifetime,
  // including network/crypto work preceding its first write. Nested work belongs
  // to the accepted operation; a detached callback loses admission on completion.
  Future<T> _operation<T>(
    Future<T> Function() fn, {
    Object? failureKey,
    bool admitted = false,
  }) {
    // Nested writes still need their own failure identity and lifetime. In
    // particular a final editor flush must clear a retried note's failure, and
    // a detached accepted child must drain even if its parent already returned.
    if (_updatePrepared && !admitted && !_insideOperation) {
      return Future.error(
        StateError(
          tr(
            'Trwa przygotowanie aktualizacji.',
            'An update is being prepared.',
          ),
        ),
      );
    }
    final token = _NotebookOperation();
    final key = failureKey ?? Object();
    final result = Future<T>.sync(
      () => runZoned(fn, zoneValues: {_operationZoneKey: token}),
    );
    late final Future<void> settled;
    settled = result
        .then<void>(
          (_) {
            _updateWriteFailures.remove(key);
          },
          onError: (Object error, StackTrace stack) {
            _updateWriteFailures[key] = error;
          },
        )
        .whenComplete(() {
          token.active = false;
          _pendingOperations.remove(settled);
        });
    _pendingOperations.add(settled);
    return result;
  }

  // Extension entry points can write on a renderer/export path, not only sync.
  Future<Uint8List> imageBytes(String vaultId, String id) => _operation(
    () => NotebookImages(this).imageBytes(vaultId, id),
    failureKey: ('image', vaultId, id),
  );

  Future<Note> noteWithEmbeddedImages(Note note) => _operation(
    () => NotebookImages(this).noteWithEmbeddedImages(note),
    failureKey: ('embedded-images', note.vaultId, note.id),
  );

  Future<void> retryVaultDeletions() => _operation(
    () => NotebookVaultDeletion(this).retryVaultDeletions(),
    failureKey: 'retry-vault-deletions',
  );

  /// Stop admission synchronously, then drain every previously accepted write.
  /// Network/crypto continuations of accepted work retain admission until done.
  Future<void> prepareForUpdate({Future<void> Function()? flush}) async {
    if (_updatePrepared) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie operacji przed aktualizacją.',
          'Wait for the operation to finish before updating.',
        ),
      );
    }
    _updatePrepared = true;
    try {
      await _drainUpdateOperations();
      // Only the captured editor flush is admitted after fencing. Run it after
      // accepted background work so an older continuation cannot overwrite it.
      if (flush != null) {
        await _operation(flush, admitted: true, failureKey: 'update-flush');
        await _drainUpdateOperations();
      }
      if (_updateWriteFailures.isNotEmpty) {
        throw StateError(
          tr(
            'Nie potwierdzono zapisu zmian. Uruchom ponownie aplikację przed aktualizacją.',
            'Saving changes was not confirmed. Restart the app before updating.',
          ),
        );
      }
      await lockHidden();
      _checkpointForUpdate();
    } catch (_) {
      _updatePrepared = false;
      rethrow;
    }
  }

  Future<void> _drainUpdateOperations() async {
    await _tail;
    while (_pendingOperations.isNotEmpty) {
      await Future.wait(_pendingOperations.toList());
      await _tail;
    }
  }

  // NativeStorage's normal close checkpoint is deliberately best effort. An
  // updater handoff requires an explicit result (busy is a result row, not an
  // exception). Never remove WAL/SHM or change the existing journal mode.
  void _checkpointForUpdate() {
    final current = storage;
    if (current is! NativeStorage) return;
    final result = current.db.select('PRAGMA wal_checkpoint(TRUNCATE)');
    if (result.isEmpty || (result.first.values.first as int) != 0) {
      throw StateError(
        tr(
          'Nie udało się zakończyć zapisu bazy przed aktualizacją.',
          'Could not finish saving the database before updating.',
        ),
      );
    }
  }

  void resumeAfterUpdate() {
    _updatePrepared = false;
  }

  bool _syncing = false;
  bool _hiddenMoving = false;
  final _deletingVaults = <String>{};
  bool _vaultDeletionBusy = false;
  final _vaultDeletions = StreamController<String>.broadcast(sync: true);
  Stream<String> get vaultDeletions => _vaultDeletions.stream;
  Future<void> Function(String id)? revokeVaultSnapshot;
  final _localChanges = StreamController<void>.broadcast();
  Stream<void> get localChanges => _localChanges.stream;
  // Access changes revoke launcher visibility without waking network sync.
  final _accessChanges = StreamController<void>.broadcast(sync: true);
  Stream<void> get accessChanges => _accessChanges.stream;
  String? mirrorWarning;
  List<Vault> get vaults => storage.vaults().map((v) {
    // The protected name in storage is a fixed redaction marker, not user data.
    // Translate only this display projection; toJson keeps its legacy wire value.
    v.name =
        _names[v.id] ??
        (v.protected ? tr('Chroniony vault', 'Protected vault') : v.name);
    return v;
  }).toList();
  Future<T> serialized<T>(Future<T> Function() fn, {Object? failureKey}) {
    if (_updatePrepared && !_insideOperation) {
      return Future.error(
        StateError(
          tr(
            'Trwa przygotowanie aktualizacji.',
            'An update is being prepared.',
          ),
        ),
      );
    }
    return _enqueue(fn, failureKey: failureKey);
  }

  Future<T> _enqueue<T>(Future<T> Function() fn, {Object? failureKey}) {
    final key = failureKey ?? Object();
    final result = _tail.then(
      (_) => _operation(fn, admitted: true, failureKey: key),
    );
    _tail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> initialize() =>
      _operation(_initialize, failureKey: 'initialize');
  Future<void> _initialize() async {
    final stored = await keys.read('nova.localKey');
    localKey = stored == null ? crypto.randomKey() : base64Decode(stored);
    if (stored == null) {
      await keys.write('nova.localKey', base64Encode(localKey));
    }
    _lastVaultId = await keys.read('nova.lastVault');
    await _loadIdentity('local');
    final cached = await keys.read('nova.session');
    if (cached != null) {
      session = Session.fromJson(jsonDecode(cached) as Json);
      await _loadIdentity('${session!.server}|${session!.email.toLowerCase()}');
      api = SiliqueApi(session!.server, token: session!.token, trust: trust);
      final master = await keys.read(await _accountSlot(session!.owner));
      if (master != null) accountKey = base64Decode(master);
    }
    await loadHiddenSettings();
    _deletingVaults.addAll((await storage.deletionIntents()).keys);
    for (final vault in vaults.where(
      (v) => !v.protected && !vaultDeletionPending(v.id),
    )) {
      await unlock(vault);
    }
  }

  Future<String> _accountSlot(String owner) async =>
      'nova.account.${await crypto.stableId(localKey, owner)}';
  Future<List<int>> _unwrapPassword(
    String id,
    String wrap,
    String password, {
    bool recovery = false,
  }) async {
    final j = jsonDecode(wrap) as Json;
    final key = recovery
        ? _recoveryBytes(password)
        : await crypto.passwordKey(password, base64Decode(j['salt'] as String));
    return base64Decode(
      await crypto.openCompat(
        key,
        j[recovery ? 'recovery' : 'wrapped'] as String,
        'silique:2:vault-key:$id${recovery ? ':recovery' : ''}',
        'nova:1:vault-key:$id${recovery ? ':recovery' : ''}',
      ),
    );
  }

  List<int> _recoveryBytes(String value) {
    final bytes = base64Url.decode(base64Url.normalize(value.trim()));
    if (bytes.length != 32) {
      throw FormatException(
        tr(
          'Klucz odzyskiwania musi mieć 32 bajty.',
          'The recovery key must contain 32 bytes.',
        ),
      );
    }
    return bytes;
  }

  Future<String> _passwordWrap(
    String id,
    List<int> key,
    String password,
    List<int> recoveryKey,
  ) async {
    final salt = crypto.randomKey().sublist(0, 16);
    final wrapping = await crypto.passwordKey(password, salt);
    return jsonEncode({
      'mode': 'password',
      'salt': base64Encode(salt),
      'kdf': {
        'name': 'argon2id',
        'memory': 65536,
        'iterations': 3,
        'parallelism': 1,
      },
      'wrapped': await crypto.seal(
        wrapping,
        base64Encode(key),
        'silique:2:vault-key:$id',
      ),
      'recovery': await crypto.seal(
        recoveryKey,
        base64Encode(key),
        'silique:2:vault-key:$id:recovery',
      ),
    });
  }

  Future<void> refreshDevices() async {
    final client = api;
    if (client == null) {
      devices = null;
      return;
    }
    final response = await client.request('GET', '/v1/devices');
    if (api == client) {
      devices = (response['devices'] as List)
          .cast<Json>()
          .where((device) => device['revoked'] != 1)
          .toList();
    }
  }

  /// The name this device presents to its account.
  ///
  /// The name is persisted in the key store so that a later login never resets
  /// it to a constant product name. A user rename is stored here as well.
  Future<String> deviceName() async {
    final stored = (await keys.read('nova.deviceName'))?.trim();
    if (stored != null && stored.isNotEmpty) return stored;
    final host = Platform.localHostname.trim();
    return host.isNotEmpty ? host : 'Silique • ${Platform.operatingSystem}';
  }

  /// Renames [targetId] on the server, then mirrors the name locally.
  ///
  /// Only an authenticated, unrevoked device of the signed-in account can be
  /// renamed; the server enforces that with an owner-and-revoked predicate. A
  /// failed request never leaves the local list claiming success, because the
  /// cached list is updated only after the server confirms the new value.
  Future<String> renameDevice(String targetId, String name) => _operation(
    () => _renameDevice(targetId, name),
    failureKey: ('rename-device', targetId),
  );
  Future<String> _renameDevice(String targetId, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      throw FormatException(
        tr(
          'Nazwa urządzenia musi mieć od 1 do 80 znaków.',
          'The device name must contain 1 to 80 characters.',
        ),
      );
    }
    final client = api;
    if (client == null || session == null) {
      throw StateError(
        tr(
          'Połącz konto, aby zmienić nazwę urządzenia.',
          'Connect an account to rename the device.',
        ),
      );
    }
    final response = await client.request(
      'PUT',
      '/v1/devices/$targetId/name',
      body: {'name': trimmed},
    );
    final saved = (response['name'] as String?)?.trim();
    if (saved == null || saved.isEmpty) {
      throw FormatException(
        tr(
          'Serwer nie potwierdził nowej nazwy urządzenia.',
          'The server did not confirm the new device name.',
        ),
      );
    }
    devices = devices
        ?.map(
          (device) =>
              device['id'] == targetId ? {...device, 'name': saved} : device,
        )
        .toList();
    if (targetId == deviceId) await keys.write('nova.deviceName', saved);
    return saved;
  }

  Future<void> moveStorage(String destination) => serialized(() async {
    if (_syncing) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie synchronizacji.',
          'Wait for synchronization to finish.',
        ),
      );
    }
    final current = storage;
    if (current is! NativeStorage) {
      throw StateError(
        tr(
          'Magazyn nie obsługuje przenoszenia.',
          'This storage does not support relocation.',
        ),
      );
    }
    final support = await getApplicationSupportDirectory();
    storage = await current.relocate(destination, support.path);
  });

  /// Folder paths stored in the vault metadata (empty folders included).
  ///
  /// The list lives in the existing encrypted `metadata` envelope under the
  /// additional `folders` key. Older clients ignore unknown keys, so the sync
  /// format stays compatible and no synthetic notes are created for folders.
  List<String> foldersOf(String vaultId) =>
      ((_meta[vaultId]?['folders'] as List?) ?? const []).cast<String>();

  /// Distinct folders referenced by live notes.
  ///
  /// Notes in the trash keep their folder so a restore returns them to the right
  /// place, but they must not keep an otherwise empty folder in the tree.
  Set<String> noteFolders(String vaultId) => {
    for (final note in notes[vaultId]?.values ?? const <Note>[])
      if (!note.deleted && note.folder.trim().isNotEmpty) note.folder,
  };

  /// Every folder that the tree must show, stored or implied by a note path.
  Set<String> allFolders(String vaultId) =>
      collectFolderPaths(foldersOf(vaultId), noteFolders(vaultId));

  Map<String, List<String>> folderOrderOf(String vaultId) =>
      decodeFolderOrder(_meta[vaultId]?['folderOrder']);

  /// Folder color preferences (`{folder path: ARGB int}`) from the encrypted
  /// vault metadata; empty when the key is absent or the vault is locked.
  ///
  /// Like [folderOrderOf], colors are a pure presentation preference under
  /// their own metadata key. They never create folders and never touch
  /// membership, notes or revisions.
  Map<String, int> folderColorsOf(String vaultId) =>
      decodeFolderColors(_meta[vaultId]?['folderColors']);

  /// Note color preferences (`{noteId: ARGB int}`) from the encrypted vault
  /// metadata; empty when the key is absent or the vault is locked.
  ///
  /// Like [folderColorsOf], these are a pure presentation preference under
  /// their own metadata key. They never touch note documents or revisions, and
  /// an orphaned entry for a purged note is harmless — the UI only reads a
  /// color for a note it is already rendering.
  Map<String, int> noteColorsOf(String vaultId) =>
      decodeNoteColors(_meta[vaultId]?['noteColors']);

  /// Default note icon color (ARGB int) read from the `defaultNoteColor`
  /// metadata key, falling back to [kDefaultNoteColor] when absent, invalid or
  /// the vault is locked.
  int defaultNoteColorOf(String vaultId) =>
      decodeDefaultColor(_meta[vaultId]?['defaultNoteColor']) ??
      kDefaultNoteColor;

  /// Default folder icon color (ARGB int) read from the `defaultFolderColor`
  /// metadata key; `null` when absent, invalid or the vault is locked. `null`
  /// means folders without an explicit color keep their colorless look.
  int? defaultFolderColorOf(String vaultId) =>
      decodeDefaultColor(_meta[vaultId]?['defaultFolderColor']);

  /// Compact sidebar preference (`true` merges the folder and note lists into
  /// one hierarchical list) from the encrypted vault metadata; `false` when
  /// the key is absent or the vault is locked.
  ///
  /// Like [folderOrderOf], this is a pure presentation preference under its
  /// own metadata key. It never touches folders, notes or revisions.
  bool compactModeOf(String vaultId) =>
      decodeCompactMode(_meta[vaultId]?['compactMode']);

  List<FolderEntry> folderRowsOf(
    String vaultId, {
    Set<String> collapsed = const {},
  }) => !unlocked.containsKey(vaultId)
      ? []
      : buildFolderTree(
          allFolders(vaultId),
          collapsed: collapsed,
          order: folderOrderOf(vaultId),
        );

  /// Reorder only existing ordinary siblings. No document or revision changes.
  Future<void> reorderFolder(
    Vault vault,
    String source,
    String sibling, {
    required bool after,
  }) => serialized(() async {
    _requireLiveVault(vault.id);
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final paths = allFolders(vault.id);
    if (!paths.contains(source) ||
        !paths.contains(sibling) ||
        folderParent(source) != folderParent(sibling)) {
      throw ArgumentError(
        tr(
          'Wybierz foldery na tym samym poziomie.',
          'Choose folders at the same level.',
        ),
      );
    }
    if (source == sibling) return;
    final parent = folderParent(source);
    final siblings =
        folderRowsOf(vault.id)
            .where((row) => folderParent(row.path) == parent)
            .map((row) => row.path)
            .toList()
          ..remove(source);
    siblings.insert(siblings.indexOf(sibling) + (after ? 1 : 0), source);
    final order = folderOrderOf(vault.id)..[parent] = siblings;
    if (sameFolderOrder(order, folderOrderOf(vault.id))) return;
    await _writeMeta(vault, folderOrder: order, offlineTolerant: true);
  }, failureKey: ('reorder-folder', vault.id));

  /// Sets the color of an existing folder, or clears it with `null`.
  ///
  /// The path must normalize to a folder the vault already has; the color must
  /// be a 32-bit ARGB value. Rejected input never reaches storage. The write
  /// goes through the same metadata path as folder order (offline-tolerant,
  /// with a confirmed merge base), so a lost server response keeps the local
  /// preference for the next sync instead of failing the request. Returns
  /// whether the server confirmed the change; `true` also when the preference
  /// already matched and no write was needed.
  Future<bool> setFolderColor(Vault vault, String path, int? color) =>
      serialized(() async {
        _requireLiveVault(vault.id);
        if (!unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        final normalized = normalizeFolderPath(path);
        if (normalized == null || !allFolders(vault.id).contains(normalized)) {
          throw ArgumentError(
            tr('Wybierz istniejący folder.', 'Choose an existing folder.'),
          );
        }
        if (color != null && (color < 0 || color > 0xFFFFFFFF)) {
          throw ArgumentError(
            tr(
              'Kolor musi być 32-bitową wartością ARGB.',
              'The color must be a 32-bit ARGB value.',
            ),
          );
        }
        final colors = folderColorsOf(vault.id);
        if (color == null) {
          if (colors.remove(normalized) == null) return true;
        } else {
          if (colors[normalized] == color) return true;
          colors[normalized] = color;
        }
        return await _writeMeta(
          vault,
          folderColors: colors,
          offlineTolerant: true,
        );
      }, failureKey: ('folder-color', vault.id));

  /// Sets the color of a note, or clears it with `null` (which removes the
  /// entry). Unlike [setFolderColor], no existence check is performed: the
  /// note may already be purged, and an orphaned entry must never surface as an
  /// error. The color must be a 32-bit ARGB value. The write goes through the
  /// same offline-tolerant metadata path as folder colors, so a lost server
  /// response keeps the local preference for the next sync.
  Future<bool> setNoteColor(Vault vault, String noteId, int? color) =>
      serialized(() async {
        _requireLiveVault(vault.id);
        if (!unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        if (color != null && (color < 0 || color > 0xFFFFFFFF)) {
          throw ArgumentError(
            tr(
              'Kolor musi być 32-bitową wartością ARGB.',
              'The color must be a 32-bit ARGB value.',
            ),
          );
        }
        final colors = noteColorsOf(vault.id);
        if (color == null) {
          if (colors.remove(noteId) == null) return true;
        } else {
          if (colors[noteId] == color) return true;
          colors[noteId] = color;
        }
        return await _writeMeta(
          vault,
          noteColors: colors,
          offlineTolerant: true,
        );
      }, failureKey: ('note-color', vault.id));

  /// Stores the default note icon color for [vault] under the
  /// `defaultNoteColor` metadata key. Every new note without an explicit color
  /// renders its icon in this value. The write goes through the same
  /// offline-tolerant metadata path as folder colors, so a lost server
  /// response keeps the preference for the next sync. Returns whether the
  /// server confirmed the change; `true` also when the value already matched.
  Future<bool> setDefaultNoteColor(Vault vault, int argb) =>
      serialized(() async {
        _requireLiveVault(vault.id);
        if (!unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        if (argb < 0 || argb > 0xFFFFFFFF) {
          throw ArgumentError(
            tr(
              'Kolor musi być 32-bitową wartością ARGB.',
              'The color must be a 32-bit ARGB value.',
            ),
          );
        }
        if (decodeDefaultColor(_meta[vault.id]?['defaultNoteColor']) == argb) {
          return true;
        }
        return await _writeMeta(
          vault,
          defaultNoteColor: argb,
          offlineTolerant: true,
        );
      }, failureKey: ('default-note-color', vault.id));

  /// Stores the default folder icon color for [vault] under the
  /// `defaultFolderColor` metadata key, or clears it with `null` (folders then
  /// keep their colorless look unless they carry an explicit color). The write
  /// goes through the same offline-tolerant metadata path as folder colors.
  /// Returns whether the server confirmed the change; `true` also when the
  /// value already matched.
  Future<bool> setDefaultFolderColor(Vault vault, int? argb) =>
      serialized(() async {
        _requireLiveVault(vault.id);
        if (!unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        if (argb != null && (argb < 0 || argb > 0xFFFFFFFF)) {
          throw ArgumentError(
            tr(
              'Kolor musi być 32-bitową wartością ARGB.',
              'The color must be a 32-bit ARGB value.',
            ),
          );
        }
        if (defaultFolderColorOf(vault.id) == argb) return true;
        return await _writeMeta(
          vault,
          defaultFolderColor: argb,
          offlineTolerant: true,
        );
      }, failureKey: ('default-folder-color', vault.id));

  /// Removes every explicit note color for [vault], so all notes render the
  /// vault's default note color. Used by the appearance settings "apply to
  /// existing" action. Mirrors [setNoteColor]'s offline-tolerant metadata path.
  Future<bool> clearNoteColors(Vault vault) => serialized(() async {
    _requireLiveVault(vault.id);
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    if (noteColorsOf(vault.id).isEmpty) return true;
    return await _writeMeta(vault, noteColors: const {}, offlineTolerant: true);
  }, failureKey: ('clear-note-colors', vault.id));

  /// Removes every explicit folder color for [vault], so all folders render
  /// the vault's default folder color (or their colorless look when unset).
  /// Mirrors [setFolderColor]'s offline-tolerant metadata path.
  Future<bool> clearFolderColors(Vault vault) => serialized(() async {
    _requireLiveVault(vault.id);
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    if (folderColorsOf(vault.id).isEmpty) return true;
    return await _writeMeta(
      vault,
      folderColors: const {},
      offlineTolerant: true,
    );
  }, failureKey: ('clear-folder-colors', vault.id));

  /// Stores the compact-mode presentation preference for [vault].
  ///
  /// The flag lives as a sibling key in the same encrypted metadata envelope
  /// as the folder order and colors; the write goes through the same path
  /// (offline-tolerant, with a confirmed merge base), so a lost server
  /// response keeps the local preference for the next sync instead of failing
  /// the request. Returns whether the server confirmed the change; `true` also
  /// when the preference already matched and no write was needed.
  Future<bool> setCompactMode(Vault vault, bool enabled) =>
      serialized(() async {
        _requireLiveVault(vault.id);
        if (!unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        if (compactModeOf(vault.id) == enabled) return true;
        return await _writeMeta(
          vault,
          compactMode: enabled,
          offlineTolerant: true,
        );
      }, failureKey: ('compact-mode', vault.id));

  /// The folder list the server confirmed last, or `null` when unknown.
  ///
  /// The value is an encrypted snapshot stored with the vault record, so even a
  /// protected vault never writes folder names in clear text to disk.
  Future<List<String>?> folderBaseOf(Vault vault) async {
    final snapshot = await _folderBaseSnapshot(vault);
    return snapshot == null
        ? null
        : (snapshot['folders'] as List).cast<String>();
  }

  Future<Json?> _folderBaseSnapshot(Vault vault) async {
    final sealed = vault.folderBase;
    final key = unlocked[vault.id];
    if (sealed.isEmpty || key == null) return null;
    try {
      final plain = await crypto.openCompat(
        key,
        sealed,
        'silique:2:folder-base:${vault.id}',
        'nova:1:folder-base:${vault.id}',
      );
      final decoded = jsonDecode(plain);
      return decoded is List ? {'folders': decoded} : decoded as Json;
    } catch (_) {
      return null;
    }
  }

  Future<void> _setFolderBase(
    Vault vault,
    List<String> folders, {
    Map<String, List<String>>? order,
    Map<String, int>? colors,
    bool? compactMode,
    Map<String, int>? noteColors,
    int? defaultNoteColor,
    int? defaultFolderColor,
  }) async {
    final key = unlocked[vault.id];
    if (key == null) return;
    vault.folderBase = await crypto.seal(
      key,
      jsonEncode({
        'folders': folders,
        'folderOrder': order ?? folderOrderOf(vault.id),
        'folderColors': colors ?? folderColorsOf(vault.id),
        'compactMode': compactMode ?? compactModeOf(vault.id),
        'noteColors': noteColors ?? noteColorsOf(vault.id),
        'defaultNoteColor': defaultNoteColor,
        'defaultFolderColor': defaultFolderColor,
      }),
      'silique:2:folder-base:${vault.id}',
    );
  }

  static bool _sameFolders(Iterable<String> a, Iterable<String> b) {
    final left = a.toSet(), right = b.toSet();
    return left.length == right.length && left.containsAll(right);
  }

  Future<void> renameVault(Vault vault, String name) => serialized(() async {
    if (name.trim().isEmpty) {
      throw FormatException(tr('Podaj nazwę vaulta.', 'Enter a vault name.'));
    }
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    await _writeMeta(vault, name: name.trim());
    vault.name = name.trim();
    _names[vault.id] = vault.name;
    storage.putVault(vault);
  }, failureKey: ('rename-vault', vault.id));

  /// Persists [vault] metadata and mirrors it to the owner's server.
  ///
  /// The vault metadata envelope already carries the vault name; folders are
  /// added as a further JSON key. For a synced vault the server write uses its
  /// version compare-and-swap, so a lost response or a concurrent rename fails
  /// loudly instead of silently discarding folders on another device.
  Future<bool> _writeMeta(
    Vault vault, {
    String? name,
    List<String>? folders,
    Map<String, List<String>>? folderOrder,
    Map<String, int>? folderColors,
    Map<String, int>? noteColors,
    bool? compactMode,
    int? defaultNoteColor,
    Object? defaultFolderColor = _keepDefaultFolderColor,
    Json? metadataBase,
    bool offlineTolerant = false,
  }) async {
    _requireLiveVault(vault.id);
    final key = unlocked[vault.id];
    if (key == null) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final meta = <String, dynamic>{
      ...?(metadataBase ?? _meta[vault.id]),
      'name': name ?? _names[vault.id] ?? vault.name,
      'folders': folders ?? foldersOf(vault.id),
      'folderOrder': ?folderOrder,
      'folderColors': ?folderColors,
      'noteColors': ?noteColors,
      'compactMode': ?compactMode,
      'defaultNoteColor': ?defaultNoteColor,
      if (!identical(defaultFolderColor, _keepDefaultFolderColor))
        'defaultFolderColor': defaultFolderColor,
    };
    final sealed = await crypto.seal(
      key,
      jsonEncode(meta),
      'silique:2:vault-meta:${vault.id}',
    );
    if (!identical(unlocked[vault.id], key)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final previousMeta = _meta[vault.id];
    final previousSealed = vault.metadata;
    final previousVersion = vault.version;
    final applied = List<String>.of(folders ?? foldersOf(vault.id));
    final appliedOrder = folderOrder ?? folderOrderOf(vault.id);
    final appliedColors = folderColors ?? folderColorsOf(vault.id);
    final appliedNoteColors = noteColors ?? noteColorsOf(vault.id);
    final appliedCompact = compactMode ?? compactModeOf(vault.id);
    final appliedDefaultNoteColor =
        defaultNoteColor ??
        decodeDefaultColor(_meta[vault.id]?['defaultNoteColor']);
    final appliedDefaultFolderColor =
        identical(defaultFolderColor, _keepDefaultFolderColor)
        ? decodeDefaultColor(_meta[vault.id]?['defaultFolderColor'])
        : defaultFolderColor as int?;
    _meta[vault.id] = meta;
    vault.metadata = sealed;
    var confirmed = vault.owner == null || !vault.syncEnabled;
    if (vault.owner != null && vault.syncEnabled) {
      if (session?.owner != vault.owner || api == null) {
        _restoreMeta(vault.id, previousMeta);
        vault.metadata = previousSealed;
        throw StateError(
          tr(
            'Połącz konto właściciela vaulta.',
            'Connect the vault owner\'s account.',
          ),
        );
      }
      // Rewrap the server key wrap to silique:2 on the first post-update
      // write; a CAS conflict below keeps the previous wrap untouched.
      final previousWrap = vault.keyWrap;
      try {
        vault.keyWrap = await _rewrapAccountKeyWrap(vault);
        final response = await api!.request(
          'PUT',
          '/v1/vaults/${vault.id}',
          body: {
            'keyWrap': vault.keyWrap,
            'metadata': sealed,
            'expectedVersion': vault.version,
          },
        );
        vault.version = response['version'] as int;
        confirmed = true;
      } catch (_) {
        if (vault.keyWrap != previousWrap) vault.keyWrap = previousWrap;
        _restoreMeta(vault.id, previousMeta);
        vault.metadata = previousSealed;
        vault.version = previousVersion;
        if (!offlineTolerant) rethrow;
        // Offline change: keep the local metadata and leave the confirmed base
        // untouched, so the next sync still sees these folders as local edits.
        if (identical(unlocked[vault.id], key)) _meta[vault.id] = meta;
        vault.metadata = sealed;
      }
    }
    // Only a server-confirmed list becomes the new merge base.
    if (confirmed) {
      await _setFolderBase(
        vault,
        applied,
        order: appliedOrder,
        colors: appliedColors,
        compactMode: appliedCompact,
        noteColors: appliedNoteColors,
        defaultNoteColor: appliedDefaultNoteColor,
        defaultFolderColor: appliedDefaultFolderColor,
      );
    }
    storage.putVault(vault);
    return confirmed;
  }

  void _restoreMeta(String vaultId, Json? meta) {
    if (meta == null || !unlocked.containsKey(vaultId)) {
      _meta.remove(vaultId);
    } else {
      _meta[vaultId] = meta;
    }
  }

  /// Rewraps a synced vault's server-side account key wrap with the new
  /// `silique:2:` AAD once, before the first CAS write after the update.
  ///
  /// Only the account-mode wrap (the `wrapped` field sealed with the account
  /// key) is rewritten; password-mode wraps are resealed by their own write
  /// paths. An already `silique:2:` wrap and a foreign account both leave the
  /// wrap unchanged. The returned value is the wrap to send; the caller still
  /// performs the compare-and-swap, so a lost CAS never corrupts the server.
  Future<String> _rewrapAccountKeyWrap(Vault vault) async {
    if (vault.protected || accountKey == null) return vault.keyWrap;
    final j = jsonDecode(vault.keyWrap) as Json;
    final sealed = j['wrapped'];
    if (j['mode'] != 'account' || sealed is! String) return vault.keyWrap;
    // Already rewrapped: opening with the new AAD succeeds and nothing changes.
    try {
      await crypto.open(accountKey!, sealed, 'silique:2:vault-key:${vault.id}');
      return vault.keyWrap;
    } on SecretBoxAuthenticationError {
      // Falls through to the legacy rewrite below.
    }
    final key = base64Decode(
      await crypto.open(
        accountKey!,
        sealed,
        'nova:1:vault-key:${vault.id}',
      ),
    );
    return jsonEncode({
      'mode': 'account',
      'wrapped': await crypto.seal(
        accountKey!,
        base64Encode(key),
        'silique:2:vault-key:${vault.id}',
      ),
    });
  }

  /// Creates a durable folder, including empty folders, at a validated [path].
  Future<void> createFolder(Vault vault, String path) => serialized(() async {
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final normalized = normalizeFolderPath(path);
    if (normalized == null) {
      throw FormatException(
        folderPathError(path) ?? tr('Nieprawidłowa ścieżka.', 'Invalid path.'),
      );
    }
    final existing = allFolders(vault.id);
    if (existing.contains(normalized)) {
      throw StateError(
        tr(
          'Folder „$normalized” już istnieje.',
          'Folder “$normalized” already exists.',
        ),
      );
    }
    if (folderPathCollides(normalized, existing)) {
      throw StateError(
        tr(
          'Folder o tej nazwie już istnieje (nazwy różnią się tylko wielkością liter).',
          'A folder with this name already exists (the names differ only in letter case).',
        ),
      );
    }
    await _writeMeta(
      vault,
      folders: [...foldersOf(vault.id), normalized],
      offlineTolerant: true,
    );
  });

  /// Renames or moves a folder and every note inside its subtree.
  Future<int> renameFolder(
    Vault vault,
    String from,
    String to,
  ) => serialized(() async {
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    final source = normalizeFolderPath(from);
    final target = normalizeFolderPath(to);
    if (source == null || target == null) {
      throw FormatException(
        folderPathError(to) ?? tr('Nieprawidłowa ścieżka.', 'Invalid path.'),
      );
    }
    if (source == target) return 0;
    if (isSameOrDescendantPath(target, source)) {
      throw StateError(
        tr(
          'Nie można przenieść folderu do niego samego.',
          'A folder cannot be moved into itself.',
        ),
      );
    }
    final collision = folderMoveCollision(
      from: source,
      to: target,
      existing: allFolders(vault.id),
    );
    if (collision != null) {
      throw StateError(
        tr(
          'Folder docelowy już istnieje: $collision.',
          'The destination folder already exists: $collision.',
        ),
      );
    }
    // Metadata first: a rejected server write must not leave the notes moved
    // into a folder that the vault does not know about.
    await _writeMeta(
      vault,
      folderOrder: remapFolderOrder(folderOrderOf(vault.id), source, target),
      folderColors: remapFolderColors(folderColorsOf(vault.id), source, target),
      folders: [
        for (final path in foldersOf(vault.id))
          if (path == source || isDescendantPath(path, source))
            replacePathPrefix(path, source, target)
          else
            path,
      ],
      offlineTolerant: true,
    );
    var changed = 0;
    for (final note in (notes[vault.id]?.values ?? const <Note>[]).toList()) {
      if (note.folder != source && !isDescendantPath(note.folder, source)) {
        continue;
      }
      await _saveNote(
        note.copyWith(folder: replacePathPrefix(note.folder, source, target)),
      );
      changed++;
    }
    return changed;
  });

  /// Trashes every note in the folder subtree and forgets the folders.
  Future<int> trashFolder(Vault vault, String path) => serialized(() async {
    final source = normalizeFolderPath(path);
    if (source == null) {
      throw FormatException(tr('Nieprawidłowa ścieżka.', 'Invalid path.'));
    }
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    var changed = 0;
    for (final note in (notes[vault.id]?.values ?? const <Note>[]).toList()) {
      if (note.deleted) continue;
      if (note.folder != source && !isDescendantPath(note.folder, source)) {
        continue;
      }
      await _saveNote(note.copyWith(deleted: true));
      changed++;
    }
    await _writeMeta(
      vault,
      folderOrder: remapFolderOrder(folderOrderOf(vault.id), source, null),
      folderColors: remapFolderColors(folderColorsOf(vault.id), source, null),
      folders: [
        for (final folder in foldersOf(vault.id))
          if (folder != source && !isDescendantPath(folder, source)) folder,
      ],
      offlineTolerant: true,
    );
    return changed;
  });

  /// Moves [targets] into [folder] (empty string means the vault root).
  ///
  /// The destination is validated and implicitly added to the vault metadata so
  /// that an otherwise empty target folder stays visible after a restart.
  Future<int> moveNotes(Iterable<Note> targets, String folder) =>
      serialized(() async {
        final list = targets.toList();
        if (list.isEmpty) return 0;
        final vaultId = list.first.vaultId;
        if (!unlocked.containsKey(vaultId)) {
          throw StateError(
            tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
          );
        }
        if (list.any((note) => note.vaultId != vaultId)) {
          throw StateError(
            tr(
              'Notatki pochodzą z różnych vaultów.',
              'The notes belong to different vaults.',
            ),
          );
        }
        final target = folder.trim().isEmpty ? '' : normalizeFolderPath(folder);
        if (target == null) {
          throw FormatException(
            folderPathError(folder) ??
                tr('Nieprawidłowa ścieżka folderu.', 'Invalid folder path.'),
          );
        }
        if (target.isNotEmpty) {
          final existing = allFolders(vaultId);
          if (!existing.contains(target)) {
            await _writeMeta(
              vaults.firstWhere((v) => v.id == vaultId),
              folders: [...foldersOf(vaultId), target],
              offlineTolerant: true,
            );
          }
        }
        var changed = 0;
        for (final note in list) {
          final current = notes[vaultId]?[note.id] ?? note;
          if (current.folder == target) continue;
          await _saveNote(current.copyWith(folder: target));
          changed++;
        }
        return changed;
      });

  /// Sets the pin state of [targets] and returns how many notes changed.
  Future<int> setFavoriteAll(Iterable<Note> targets, bool value) =>
      serialized(() async {
        var changed = 0;
        for (final note in targets) {
          final current = notes[note.vaultId]?[note.id] ?? note;
          if (current.favorite == value) continue;
          await _saveNote(current.copyWith(favorite: value));
          changed++;
        }
        return changed;
      });

  /// Moves [targets] to or out of the trash and returns how many changed.
  Future<int> setDeletedAll(Iterable<Note> targets, bool value) =>
      serialized(() async {
        var changed = 0;
        for (final note in targets) {
          final current = notes[note.vaultId]?[note.id] ?? note;
          if (current.deleted == value) continue;
          await _saveNote(current.copyWith(deleted: value));
          changed++;
        }
        return changed;
      });

  /// Exposes [save] without taking the serialization lock again.
  Future<void> saveWithin(Note note) => _operation(
    () => _saveNote(note),
    failureKey: ('note', note.vaultId, note.id),
  );

  Future<void> _eraseNote(
    String vaultId,
    String noteId, {
    String? hiddenDocument,
  }) async {
    final retainImages = <String>{
      for (final note in notes[vaultId]?.values ?? <Note>[])
        if (note.id != noteId)
          ...imageReferencePattern
              .allMatches(note.body)
              .map((m) => m.group(1)!),
    };
    try {
      await storage.eraseNote(
        vaultId,
        noteId,
        retainImages: retainImages.toList(),
        hiddenDocument: hiddenDocument,
      );
    } finally {
      // File cleanup/checkpoint can fail after SQL committed. Follow the
      // authoritative row, but preserve memory if the transaction rolled back.
      if (!storage.documents(vaultId).containsKey(noteId)) {
        notes[vaultId]?.remove(noteId);
        _knownHeads.remove('$vaultId:$noteId');
      }
    }
  }

  Future<void> purgeNote(Note note) => _operation(
    () => _purgeNote(note),
    failureKey: ('purge', note.vaultId, note.id),
  );
  Future<void> _purgeNote(Note note) async {
    if (note.hidden) return _purgeHidden(note);
    if (!note.deleted) {
      throw StateError(
        tr(
          'Najpierw przenieś notatkę do kosza.',
          'Move the note to the trash first.',
        ),
      );
    }
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    if (vault.owner != null) {
      if (!vault.syncEnabled || session?.owner != vault.owner) {
        throw StateError(
          tr(
            'Włącz synchronizację i połącz konto właściciela, aby usunąć notatkę na wszystkich urządzeniach.',
            'Enable synchronization and connect the owner\'s account to delete the note on all devices.',
          ),
        );
      }
      await sync();
    }
    await serialized(() async {
      if (_syncing) {
        throw StateError(
          tr(
            'Poczekaj na zakończenie synchronizacji.',
            'Wait for synchronization to finish.',
          ),
        );
      }
      if (vault.owner != null) {
        await api!.request('DELETE', '/v1/vaults/${vault.id}/notes/${note.id}');
      }
      await _eraseNote(note.vaultId, note.id);
    });
  }

  Future<String?> createVault(String name, {String? password}) => serialized(
    () async {
      if (name.trim().isEmpty) {
        throw FormatException(tr('Podaj nazwę vaulta.', 'Enter a vault name.'));
      }
      if (password != null && password.length < 12) {
        throw FormatException(
          tr(
            'Hasło vaulta wymaga co najmniej 12 znaków.',
            'The vault password must contain at least 12 characters.',
          ),
        );
      }
      final id = _uuid.v4(),
          key = crypto.randomKey(),
          recovery = crypto.randomKey();
      final wrap = password == null
          ? jsonEncode({
              'mode': 'account',
              'wrapped': await crypto.seal(
                localKey,
                base64Encode(key),
                'silique:2:vault-key:$id',
              ),
            })
          : await _passwordWrap(id, key, password, recovery);
      final v = Vault(
        id: id,
        name: name.trim(),
        mode: password == null ? 'account' : 'password',
        keyWrap: wrap,
        localWrap: password == null
            ? await crypto.seal(
                localKey,
                base64Encode(key),
                'silique:2:local-vault:$id',
              )
            : '',
        metadata: await crypto.seal(
          key,
          jsonEncode({'name': name.trim()}),
          'silique:2:vault-meta:$id',
        ),
      );
      storage.putVault(v);
      unlocked[id] = key;
      notes[id] = {};
      _names[id] = v.name;
      return password == null ? null : base64UrlEncode(recovery);
    },
  );
  Future<void> unlock(Vault vault, {String? password, bool recovery = false}) =>
      _operation(
        () => _unlock(vault, password: password, recovery: recovery),
        failureKey: ('unlock', vault.id),
      );
  Future<void> _unlock(
    Vault vault, {
    String? password,
    bool recovery = false,
  }) async {
    _requireLiveVault(vault.id);
    final key = vault.protected
        ? await _unwrapPassword(
            vault.id,
            vault.keyWrap,
            password ?? '',
            recovery: recovery,
          )
        : base64Decode(
            await crypto.openCompat(
              localKey,
              vault.localWrap,
              'silique:2:local-vault:${vault.id}',
              'nova:1:local-vault:${vault.id}',
            ),
          );
    await _unlockWithKey(vault, key);
  }

  /// Re-reads metadata and notes with a key that is already in memory.
  ///
  /// Sync uses this to refresh an unlocked protected vault without asking for
  /// the password again; locking it instead would discard local folder edits
  /// before they can be merged.
  Future<void> _unlockWithKey(Vault vault, List<int> key) async {
    _requireLiveVault(vault.id);
    final meta = jsonDecode(
      await crypto.openCompat(
        key,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
        'nova:1:vault-meta:${vault.id}',
      ),
    ) as Json;
    final loaded = <String, Note>{};
    for (final entry in storage.documents(vault.id).entries) {
      final text = vault.protected
          ? await crypto.openCompat(
              key,
              entry.value,
              'silique:2:local-note:${vault.id}:${entry.key}',
              'nova:1:local-note:${vault.id}:${entry.key}',
            )
          : entry.value;
      final decoded = jsonDecode(text) as Json;
      final note = Note.fromJson(decoded);
      _knownHeads['${vault.id}:${note.id}'] = (decoded['_heads'] as List? ?? [])
          .cast<String>();
      if (note.id != entry.key || note.vaultId != vault.id) {
        throw FormatException(
          tr('Niezgodna tożsamość notatki.', 'Note identity mismatch.'),
        );
      }
      loaded[note.id] = note;
    }
    _requireLiveVault(vault.id);
    vault.name = meta['name'] as String;
    _names[vault.id] = vault.name;
    _meta[vault.id] = meta;
    storage.putVault(vault);
    unlocked[vault.id] = key;
    notes[vault.id] = loaded;
    // Finish interrupted local cleanup before exposing this vault to the UI.
    for (final id in storage.documents(_hiddenVault(vault.id)).keys) {
      await _eraseNote(vault.id, id);
    }
    _accessChanges.add(null);
  }

  void lock(String vaultId) {
    unlocked.remove(vaultId);
    notes.remove(vaultId);
    _names.remove(vaultId);
    _meta.remove(vaultId);
    _accessChanges.add(null);
  }

  Future<void> changeVaultPassword(Vault vault, String password) =>
      serialized(() async {
        if (!vault.protected || !unlocked.containsKey(vault.id)) {
          throw StateError(
            tr(
              'Najpierw odblokuj chroniony vault.',
              'Unlock the protected vault first.',
            ),
          );
        }
        if (password.length < 12) {
          throw FormatException(
            tr(
              'Hasło wymaga co najmniej 12 znaków.',
              'The password must contain at least 12 characters.',
            ),
          );
        }
        final old = jsonDecode(vault.keyWrap) as Json;
        final salt = crypto.randomKey().sublist(0, 16),
            derived = await crypto.passwordKey(password, salt);
        old['salt'] = base64Encode(salt);
        old['wrapped'] = await crypto.seal(
          derived,
          base64Encode(unlocked[vault.id]!),
          'silique:2:vault-key:${vault.id}',
        );
        vault.keyWrap = jsonEncode(old);
        // CAS on the server precedes local replacement, preserving the old wrap on error.
        if (vault.syncEnabled) {
          if (session?.owner != vault.owner) {
            throw StateError(
              tr(
                'Zaloguj się na konto tego vaulta.',
                'Sign in to this vault\'s account.',
              ),
            );
          }
          final response = await api!.request(
            'PUT',
            '/v1/vaults/${vault.id}',
            body: {
              'keyWrap': vault.keyWrap,
              'metadata': vault.metadata,
              'expectedVersion': vault.version,
            },
          );
          vault.version = response['version'] as int;
        }
        storage.putVault(vault);
      });
  List<Revision> heads(String vaultId, String noteId) {
    final all = storage.revisions(vaultId, noteId: noteId);
    final parents = all.expand((r) => r.parents).toSet();
    return all.where((r) => !parents.contains(r.id)).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
  }

  Future<void> _document(Note note, List<String> knownHeads) async {
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    final text = jsonEncode({...note.toJson(), '_heads': knownHeads});
    storage.putDocument(
      vault.id,
      note.id,
      vault.protected
          ? await crypto.seal(
              unlocked[vault.id]!,
              text,
              'silique:2:local-note:${vault.id}:${note.id}',
            )
          : text,
    );
    notes.putIfAbsent(vault.id, () => {})[note.id] = note;
    _knownHeads['${note.vaultId}:${note.id}'] = knownHeads;
  }

  Future<void> _mirror(Note note) async {
    if (vaults.firstWhere((v) => v.id == note.vaultId).protected) return;
    try {
      await storage.mirror(note);
      mirrorWarning = null;
    } catch (_) {
      mirrorWarning = tr(
        'Notatka jest zapisana w bazie. Nie udało się odświeżyć kopii Markdown.',
        'The note is saved in the database. Could not refresh the Markdown copy.',
      );
    }
  }

  Future<Revision> _makeRevision(
    Note note,
    List<String> parents, {
    String? revisionId,
  }) async {
    final placeholder = Revision(
      id: revisionId ?? _uuid.v4(),
      vaultId: note.vaultId,
      noteId: note.id,
      parents: parents,
      payload: '',
    );
    return Revision(
      id: placeholder.id,
      vaultId: note.vaultId,
      noteId: note.id,
      parents: parents,
      payload: await crypto.seal(
        unlocked[note.vaultId]!,
        jsonEncode(note.toJson()),
        placeholder.aad,
      ),
    );
  }

  Future<void> save(Note note) {
    final failureKey = ('note', note.vaultId, note.id);
    if (!note.hidden) {
      return serialized(() => _saveNote(note), failureKey: failureKey);
    }
    // Only edits captured in an active session may drain past a lock request.
    final key = hiddenUnlocked ? _hiddenKey : null;
    return serialized(() async {
      if (key == null) {
        throw StateError(
          tr('Ukryte notatki są zablokowane.', 'Hidden notes are locked.'),
        );
      }
      await _saveHidden(note, capturedKey: key);
    }, failureKey: failureKey);
  }

  static bool _sameContent(Note a, Note b) =>
      jsonEncode(a.toJson()..remove('updatedAt')) ==
      jsonEncode(b.toJson()..remove('updatedAt'));

  /// Commits [note] immediately. Callers inside [serialized] must use this
  /// directly: [save] would wait for the very lock it is already holding.
  Future<void> _saveNote(
    Note note, {
    bool revealing = false,
    void Function()? validateCommit,
    void Function()? withinCommit,
  }) async {
    _requireLiveVault(note.vaultId);
    if (note.hidden) return _saveHidden(note);
    if (!revealing && _hiddenIdentity(note.vaultId, note.id)) {
      throw StateError(
        tr(
          'Notatka jest ukryta. Otwórz ją w sekcji Ukryte.',
          'This note is hidden. Open it in the Hidden section.',
        ),
      );
    }
    if (!unlocked.containsKey(note.vaultId)) {
      throw StateError(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    final current = notes[note.vaultId]?[note.id];
    if (!revealing && current != null && _sameContent(current, note)) return;
    if (utf8.encode(jsonEncode(note.toJson())).length > 1_000_000) {
      throw FormatException(
        tr(
          'Notatka jest zbyt duża (limit 1 MB).',
          'The note is too large (limit: 1 MB).',
        ),
      );
    }
    final rev = await _makeRevision(
      note,
      _knownHeads['${note.vaultId}:${note.id}'] ?? [],
    );
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    final document = jsonEncode({
      ...note.toJson(),
      '_heads': [rev.id],
    });
    final data = vault.protected
        ? await crypto.seal(
            unlocked[vault.id]!,
            document,
            'silique:2:local-note:${vault.id}:${note.id}',
          )
        : document;
    storage.atomic(() {
      validateCommit?.call();
      storage.putDocument(vault.id, note.id, data);
      storage.putRevision(rev, pending: true);
      withinCommit?.call();
    });
    notes.putIfAbsent(vault.id, () => {})[note.id] = note;
    _knownHeads['${note.vaultId}:${note.id}'] = [rev.id];
    await _mirror(note);
    _localChanges.add(null);
  }

  Future<Note> createNote(
    String vaultId, {
    String? journalDate,
    String folder = '',
  }) => _operation(
    () => _createNote(vaultId, journalDate: journalDate, folder: folder),
    failureKey: ('create-note', vaultId, journalDate),
  );
  Future<Note> _createNote(
    String vaultId, {
    String? journalDate,
    String folder = '',
  }) async {
    final noteId = journalDate == null
        ? _uuid.v4()
        : await crypto.stableId(unlocked[vaultId]!, 'journal:$journalDate');
    final existing = notes[vaultId]?[noteId];
    if (existing != null && !existing.deleted) return existing;
    final note = Note(
      id: noteId,
      vaultId: vaultId,
      title: journalDate ?? tr('Bez tytułu', 'Untitled'),
      body: journalDate == null
          ? ''
          : tr(
              '## Dzisiaj\n\n- [ ] \n\n## Przemyślenia\n\n',
              '## Today\n\n- [ ] \n\n## Thoughts\n\n',
            ),
      folder: journalDate == null ? folder : tr('Dziennik', 'Journal'),
      journalDate: journalDate,
      updatedAt: DateTime.now().toUtc(),
    );
    await save(note);
    return note;
  }

  Future<String?> connect(
    String server,
    String email,
    String password, {
    bool register = false,
    String? invitation,
    String? recoveryKey,
  }) => _operation(
    () => _connect(
      server,
      email,
      password,
      register: register,
      invitation: invitation,
      recoveryKey: recoveryKey,
    ),
    failureKey: 'connect',
  );
  Future<String?> _connect(
    String server,
    String email,
    String password, {
    bool register = false,
    String? invitation,
    String? recoveryKey,
  }) async {
    final transport = SiliqueApi(server, trust: trust);
    try {
      Json discovery;
      try {
        discovery = await transport.request('GET', '/.well-known/silique');
      } on ApiException catch (error) {
        if (error.status != 404) rethrow;
        discovery = await transport.request('GET', '/.well-known/nova-notes');
      }
      final features = discovery['features'] as Json?;
      if (discovery['api_version'] != '1' ||
          features?['e2ee'] != true ||
          features?['revision_dag'] != true) {
        throw StateError(
          tr(
            'Serwer nie spełnia wymagań protokołu i szyfrowania Silique.',
            'The server does not meet Silique\'s protocol and encryption requirements.',
          ),
        );
      }
      await _loadIdentity('${transport.base}|${email.toLowerCase()}');
      final auth = await transport.request(
        'POST',
        '/v1/auth/${register ? 'register' : 'login'}',
        body: {
          'email': email,
          'password': password,
          'deviceId': deviceId,
          'deviceName': await deviceName(),
          if (register && invitation != null) 'invite': invitation,
        },
      );
      transport.token = auth['token'] as String;
      final next = Session(
        server: transport.base.toString(),
        token: transport.token!,
        userId: auth['userId'] as String,
        email: email,
      );
      final slot = await _accountSlot(next.owner),
          cached = await keys.read(await _accountSlot(next.owner));
      List<int>? master = cached == null ? null : base64Decode(cached);
      String? recovery;
      if (auth['accountEnvelope'] == null) {
        master = crypto.randomKey();
        final r = crypto.randomKey();
        recovery = base64UrlEncode(r);
        await keys.write(slot, base64Encode(master));
        final envelope = await crypto.seal(
          r,
          base64Encode(master),
          'nova:1:account:${next.userId}',
        );
        await transport.request(
          'PUT',
          '/v1/account/envelope',
          body: {'envelope': envelope, 'expected': null},
        );
      } else if (master == null &&
          recoveryKey != null &&
          recoveryKey.trim().isNotEmpty) {
        master = base64Decode(
          await crypto.open(
            _recoveryBytes(recoveryKey),
            auth['accountEnvelope'] as String,
            'nova:1:account:${next.userId}',
          ),
        );
        await keys.write(slot, base64Encode(master));
      }
      await keys.write('nova.session', jsonEncode(next.toJson()));
      api?.close();
      api = transport;
      session = next;
      accountKey = master;
      if (master == null) await startPairing();
      return recovery;
    } catch (_) {
      transport.close();
      rethrow;
    }
  }

  Future<void> _loadIdentity(String scope) async {
    final slot = 'nova.identity.${await crypto.stableId(localKey, scope)}';
    final cached = await keys.read(slot);
    deviceIdentity = cached == null
        ? {...await crypto.createIdentity(), 'id': _uuid.v4()}
        : jsonDecode(cached) as Json;
    if (cached == null) await keys.write(slot, jsonEncode(deviceIdentity));
    // The persisted identity already owns this ID; a second Keychain item was
    // redundant and caused extra authorization requests after a signing change.
    deviceId = deviceIdentity['id'] as String;
  }

  String _pairContext(Json pair) => jsonEncode([
    'nova:1:pairing',
    session!.userId,
    pair['id'],
    pair['requesterId'],
    pair['requesterKey'],
    pair['approverId'],
    pair['approverKey'],
  ]);
  Future<List<Json>> pairings() async =>
      ((await api!.request('GET', '/v1/pairings'))['pairings'] as List)
          .cast<Json>();
  Future<void> startPairing() =>
      _operation(_startPairing, failureKey: 'start-pairing');
  Future<void> _startPairing() async {
    await api!.request(
      'POST',
      '/v1/pairings',
      body: {'publicKey': deviceIdentity['public']},
    );
  }

  Future<Json> offerPairing(Json pair) => _operation(
    () => _offerPairing(pair),
    failureKey: ('offer-pairing', pair['id']),
  );
  Future<Json> _offerPairing(Json pair) async {
    await api!.request(
      'POST',
      '/v1/pairings/${pair['id']}/offer',
      body: {'publicKey': deviceIdentity['public']},
    );
    return {
      ...pair,
      'approverId': deviceId,
      'approverKey': deviceIdentity['public'],
    };
  }

  Future<({List<int> key, String context, String code})> pairingDetails(
    Json pair,
  ) async {
    final requesting = pair['requesterId'] == deviceId;
    if (!requesting && pair['approverId'] != deviceId) {
      throw StateError(
        tr(
          'To parowanie należy do innego urządzenia.',
          'This pairing belongs to another device.',
        ),
      );
    }
    if (pair[requesting ? 'requesterKey' : 'approverKey'] !=
        deviceIdentity['public']) {
      throw FormatException(
        tr(
          'Serwer zmienił klucz urządzenia.',
          'The server changed the device key.',
        ),
      );
    }
    final context = _pairContext(pair);
    final key = await crypto.pairingKey(
      deviceIdentity,
      pair[requesting ? 'approverKey' : 'requesterKey'] as String,
      context,
    );
    final raw = await crypto.stableId(key, 'verify:$context');
    final code = List.generate(
      4,
      (i) => raw.substring(i * 4, i * 4 + 4),
    ).join('  ');
    return (key: key, context: context, code: code);
  }

  /// Call only after the user compares the full code on both devices.
  Future<void> approvePairing(Json pair) => _operation(
    () => _approvePairing(pair),
    failureKey: ('approve-pairing', pair['id']),
  );
  Future<void> _approvePairing(Json pair) async {
    if (accountKey == null) {
      throw StateError(
        tr(
          'To urządzenie nie ma klucza konta.',
          'This device does not have the account key.',
        ),
      );
    }
    final details = await pairingDetails(pair);
    await api!.request(
      'POST',
      '/v1/pairings/${pair['id']}/approve',
      body: {
        'envelope': await crypto.seal(
          details.key,
          base64Encode(accountKey!),
          details.context,
        ),
      },
    );
  }

  Future<bool> finishPairing(Json pair) =>
      _operation(() => _finishPairing(pair), failureKey: 'finish-pairing');
  Future<bool> _finishPairing(Json pair) async {
    if (pair['requesterId'] != deviceId || pair['envelope'] == null) {
      return false;
    }
    final details = await pairingDetails(pair);
    final master = base64Decode(
      await crypto.open(
        details.key,
        pair['envelope'] as String,
        details.context,
      ),
    );
    await keys.write(await _accountSlot(session!.owner), base64Encode(master));
    accountKey = master;
    return true;
  }

  Future<void> recoverAccount(String recovery) => _operation(
    () => _recoverAccount(recovery),
    failureKey: 'recover-account',
  );
  Future<void> _recoverAccount(String recovery) async {
    final account = await api!.request('GET', '/v1/account');
    final master = base64Decode(
      await crypto.open(
        _recoveryBytes(recovery),
        account['accountEnvelope'] as String,
        'nova:1:account:${session!.userId}',
      ),
    );
    await keys.write(await _accountSlot(session!.owner), base64Encode(master));
    accountKey = master;
  }

  Future<void> disconnect() =>
      _operation(_disconnect, failureKey: 'disconnect');
  Future<void> _disconnect() async {
    try {
      await api?.request('POST', '/v1/auth/logout');
    } catch (_) {}
    devices = null;
    await keys.delete('nova.session');
    api?.close();
    api = null;
    session = null;
    accountKey = null;
  }

  Future<void> enableSync(Vault vault) => serialized(() async {
    _requireLiveVault(vault.id);
    if (session == null || accountKey == null) {
      throw StateError(
        tr('Najpierw połącz konto.', 'Connect an account first.'),
      );
    }
    if (!unlocked.containsKey(vault.id)) {
      throw StateError(
        tr('Najpierw odblokuj vault.', 'Unlock the vault first.'),
      );
    }
    if (vault.owner != null && vault.owner != session!.owner) {
      throw StateError(
        tr(
          'Vault jest przypisany do innego konta lub serwera.',
          'The vault belongs to another account or server.',
        ),
      );
    }
    if (!vault.protected) {
      vault.keyWrap = jsonEncode({
        'mode': 'account',
        'wrapped': await crypto.seal(
          accountKey!,
          base64Encode(unlocked[vault.id]!),
          'silique:2:vault-key:${vault.id}',
        ),
      });
    }
    final response = await api!.request(
      'PUT',
      '/v1/vaults/${vault.id}',
      body: {
        'keyWrap': vault.keyWrap,
        'metadata': vault.metadata,
        'expectedVersion': vault.version,
      },
    );
    vault.version = response['version'] as int;
    vault.owner = session!.owner;
    vault.syncEnabled = true;
    await _setFolderBase(
      vault,
      foldersOf(vault.id),
      defaultNoteColor: decodeDefaultColor(
        _meta[vault.id]?['defaultNoteColor'],
      ),
      defaultFolderColor: decodeDefaultColor(
        _meta[vault.id]?['defaultFolderColor'],
      ),
    );
    storage.putVault(vault);
  });
  Future<void> sync() => _operation(_sync, failureKey: 'sync');
  Future<void> _sync() async {
    if ((_updatePrepared && !_insideOperation) ||
        _syncing ||
        _hiddenMoving ||
        api == null ||
        session == null) {
      return;
    }
    try {
      await retryVaultDeletions();
    } catch (_) {
      // A fenced intent that still fails must not abort tombstone downloads or
      // content sync for unrelated vaults; it is retried on the next pass.
    }
    if (_syncing ||
        _hiddenMoving ||
        _vaultDeletionBusy ||
        api == null ||
        session == null) {
      return;
    }
    _syncing = true;
    final client = api!;
    final owner = session!.owner;
    try {
      final remote = await client.request('GET', '/v1/vaults');
      if (api != client || session?.owner != owner) return;
      await serialized(() async {
        if (api != client || session?.owner != owner) return;
        for (final id
            in (remote['deletedVaults'] as List? ?? const []).cast<String>()) {
          await _acceptVaultTombstone(id, owner);
        }
        await _reconcileVaultDeletionIntents(
          owner,
          remote['vaults'] as List? ?? const [],
        );
      });
      if (accountKey == null || api != client || session?.owner != owner) {
        return;
      }
      await serialized(() async {
        // Capture local folders before server metadata replaces them, and decode the
        // server copy for every unlocked vault even when its version is unchanged:
        // an offline addition must still be detected and uploaded.
        final localFolders = <String, List<String>>{};
        final serverFolders = <String, List<String>>{};
        final localOrders = <String, Map<String, List<String>>>{};
        final serverOrders = <String, Map<String, List<String>>>{};
        final localColors = <String, Map<String, int>>{};
        final serverColors = <String, Map<String, int>>{};
        final localNoteColors = <String, Map<String, int>>{};
        final serverNoteColors = <String, Map<String, int>>{};
        final localCompact = <String, bool>{};
        final serverCompact = <String, bool>{};
        final localDefaultNoteColor = <String, int?>{};
        final serverDefaultNoteColor = <String, int?>{};
        final localDefaultFolderColor = <String, int?>{};
        final serverDefaultFolderColor = <String, int?>{};
        final serverDefaultFolderPresent = <String>{};
        final serverMetadata = <String, Json>{};
        final knownLocally = <String>{};
        for (final item in remote['vaults'] as List) {
          final j = item as Json;
          final id = j['id'] as String;
          if (storage.isVaultDeleted(id) || vaultDeletionPending(id)) continue;
          final existing = vaults.where((v) => v.id == id).firstOrNull;
          // The GET runs outside the writer queue. A local metadata PUT can
          // finish while it is pending; never merge that older response against
          // the newly confirmed base or write it back with the newer version.
          if (existing != null && existing.version > (j['version'] as int)) {
            continue;
          }
          localFolders[id] = foldersOf(id);
          localOrders[id] = folderOrderOf(id);
          localColors[id] = folderColorsOf(id);
          localNoteColors[id] = noteColorsOf(id);
          localCompact[id] = compactModeOf(id);
          localDefaultNoteColor[id] = decodeDefaultColor(
            _meta[id]?['defaultNoteColor'],
          );
          localDefaultFolderColor[id] = decodeDefaultColor(
            _meta[id]?['defaultFolderColor'],
          );
          final wrap = jsonDecode(j['keyWrap'] as String) as Json;
          if (existing != null) knownLocally.add(id);
          if (existing != null && existing.owner != session!.owner) {
            throw StateError(
              tr(
                'Zdalny vault koliduje z lokalnym.',
                'The remote vault conflicts with a local vault.',
              ),
            );
          }
          final v =
              existing ??
              Vault(
                id: id,
                name: 'Chroniony vault',
                mode: wrap['mode'] as String,
                keyWrap: j['keyWrap'] as String,
                localWrap: '',
                metadata: j['metadata'] as String,
                owner: session!.owner,
                syncEnabled: true,
              );
          if (existing == null || v.version < (j['version'] as int)) {
            final serverMetadata = j['metadata'] as String;
            // A locked protected vault cannot be merged: keep metadata that was
            // never confirmed by the server (it may hold offline folders) and
            // only adopt the new version, so a later unlocked sync can merge.
            final keepLocal =
                v.protected &&
                !unlocked.containsKey(id) &&
                v.folderBase.isNotEmpty &&
                v.metadata != serverMetadata;
            v.version = j['version'] as int;
            if (keepLocal) {
              // The key wrap is account-key encrypted and must follow the server
              // even while locked (password changes), otherwise a later unlock
              // would use a stale wrap. Only the vault-key encrypted metadata is
              // preserved here.
              v.keyWrap = j['keyWrap'] as String;
              storage.putVault(v);
            } else {
              v.keyWrap = j['keyWrap'] as String;
              v.metadata = serverMetadata;
              if (!v.protected) {
                final key = base64Decode(
                  await crypto.openCompat(
                    accountKey!,
                    wrap['wrapped'] as String,
                    'silique:2:vault-key:$id',
                    'nova:1:vault-key:$id',
                  ),
                );
                v.localWrap = await crypto.seal(
                  localKey,
                  base64Encode(key),
                  'silique:2:local-vault:$id',
                );
              }
              storage.putVault(v);
              // Keep an already unlocked protected vault unlocked: locking here
              // would drop the local folder edits before the merge below can
              // reconcile them.
              final openKey = unlocked[id];
              if (!v.protected) {
                await unlock(v);
              } else if (openKey != null) {
                await _unlockWithKey(v, openKey);
              }
            }
          }
          final key = unlocked[id];
          if (key != null) {
            try {
              final meta = jsonDecode(
                await crypto.openCompat(
                  key,
                  j['metadata'] as String,
                  'silique:2:vault-meta:$id',
                  'nova:1:vault-meta:$id',
                ),
              ) as Json;
              serverFolders[id] = ((meta['folders'] as List?) ?? const [])
                  .cast<String>();
              serverOrders[id] = decodeFolderOrder(meta['folderOrder']);
              serverColors[id] = decodeFolderColors(meta['folderColors']);
              serverNoteColors[id] = decodeNoteColors(meta['noteColors']);
              serverCompact[id] = decodeCompactMode(meta['compactMode']);
              serverDefaultNoteColor[id] = decodeDefaultColor(
                meta['defaultNoteColor'],
              );
              serverDefaultFolderColor[id] = decodeDefaultColor(
                meta['defaultFolderColor'],
              );
              if (meta.containsKey('defaultFolderColor')) {
                serverDefaultFolderPresent.add(id);
              }
              if (!identical(unlocked[id], key)) {
                serverFolders.remove(id);
                serverOrders.remove(id);
                serverColors.remove(id);
                serverNoteColors.remove(id);
                serverCompact.remove(id);
                serverDefaultNoteColor.remove(id);
                serverDefaultFolderColor.remove(id);
                serverDefaultFolderPresent.remove(id);
                continue;
              }
              serverMetadata[id] = meta;
            } catch (_) {
              // Unreadable remote metadata is ignored; local folders stay intact.
            }
          }
        }
        // Three-way merge per vault with the last server-confirmed folder list.
        // Only real local or remote changes count, so a stale client cannot
        // resurrect a renamed folder and independent additions both survive.
        for (final vault in vaults.where(
          (v) =>
              !vaultDeletionPending(v.id) &&
              v.syncEnabled &&
              v.owner == session!.owner &&
              unlocked.containsKey(v.id),
        )) {
          final local = knownLocally.contains(vault.id)
              ? (localFolders[vault.id] ?? foldersOf(vault.id))
              : (serverFolders[vault.id] ?? foldersOf(vault.id));
          final remoteFolders = serverFolders[vault.id];
          if (remoteFolders == null) continue;
          final snapshot = await _folderBaseSnapshot(vault);
          final storedBase = (snapshot?['folders'] as List?)?.cast<String>();
          final localOrder = knownLocally.contains(vault.id)
              ? localOrders[vault.id] ?? folderOrderOf(vault.id)
              : serverOrders[vault.id] ?? {};
          final remoteOrder = serverOrders[vault.id] ?? {};
          final baseOrder = decodeFolderOrder(snapshot?['folderOrder']);
          final mergedOrder = mergeFolderOrder(
            base: baseOrder,
            local: localOrder,
            server: remoteOrder,
          );
          // Color preferences merge per path with their own confirmed base,
          // exactly like the order preference. They are presentation only:
          // the merged folder set above is the sole authority on membership,
          // so a stale color entry can never recreate a hidden, deleted or
          // absent folder.
          final localColorsNow = knownLocally.contains(vault.id)
              ? localColors[vault.id] ?? folderColorsOf(vault.id)
              : serverColors[vault.id] ?? {};
          final remoteColors = serverColors[vault.id] ?? {};
          final baseColors = decodeFolderColors(snapshot?['folderColors']);
          final mergedColors = mergeFolderColors(
            base: baseColors,
            local: localColorsNow,
            server: remoteColors,
          );
          // Note colors merge per id with their own confirmed base, exactly
          // like folder colors. They are presentation only: an orphaned entry
          // for a purged note never recreates a note or a document.
          final localNoteColorsNow = knownLocally.contains(vault.id)
              ? localNoteColors[vault.id] ?? noteColorsOf(vault.id)
              : serverNoteColors[vault.id] ?? {};
          final remoteNoteColors = serverNoteColors[vault.id] ?? {};
          final baseNoteColors = decodeNoteColors(snapshot?['noteColors']);
          final mergedNoteColors = mergeNoteColors(
            base: baseNoteColors,
            local: localNoteColorsNow,
            server: remoteNoteColors,
          );
          // The compact-mode flag merges against its own confirmed base with
          // the same precedence: a confirmed server change wins, otherwise an
          // offline local toggle survives the sync.
          final localCompactNow = knownLocally.contains(vault.id)
              ? localCompact[vault.id] ?? compactModeOf(vault.id)
              : serverCompact[vault.id] ?? false;
          final remoteCompact = serverCompact[vault.id];
          final baseCompact = decodeCompactMode(snapshot?['compactMode']);
          final mergedCompact = mergeCompactMode(
            base: baseCompact,
            local: localCompactNow,
            server: remoteCompact ?? baseCompact,
          );
          // Default colors are single optional values merged against their own
          // confirmed base with the same precedence as the compact flag: a
          // confirmed server change wins, otherwise a local edit survives.
          final localDefaultNoteNow = knownLocally.contains(vault.id)
              ? localDefaultNoteColor[vault.id] ??
                    decodeDefaultColor(_meta[vault.id]?['defaultNoteColor'])
              : serverDefaultNoteColor[vault.id];
          final remoteDefaultNote = serverDefaultNoteColor[vault.id];
          final baseDefaultNote = decodeDefaultColor(
            snapshot?['defaultNoteColor'],
          );
          final mergedDefaultNote = mergeDefaultColor(
            base: baseDefaultNote,
            local: localDefaultNoteNow,
            server: remoteDefaultNote ?? baseDefaultNote,
          );
          final localDefaultFolderNow = knownLocally.contains(vault.id)
              ? localDefaultFolderColor[vault.id] ??
                    decodeDefaultColor(_meta[vault.id]?['defaultFolderColor'])
              : serverDefaultFolderColor[vault.id];
          final remoteDefaultFolder = serverDefaultFolderColor[vault.id];
          final remoteFolderReported = serverDefaultFolderPresent.contains(
            vault.id,
          );
          final baseDefaultFolder = decodeDefaultColor(
            snapshot?['defaultFolderColor'],
          );
          final mergedDefaultFolder = mergeDefaultColor(
            base: baseDefaultFolder,
            local: localDefaultFolderNow,
            server: remoteFolderReported
                ? remoteDefaultFolder
                : baseDefaultFolder,
          );
          // Unknown base (a client that synced before base tracking, or a copy
          // restored without it): the local list is treated as still unconfirmed
          // so remote changes apply on top of it instead of counting as local
          // removals. A brand-new client has no local folders, so it simply
          // adopts the server copy.
          final base = storedBase ?? local;
          final merged = mergeFolderSets(
            base: base,
            local: local,
            server: remoteFolders,
          );
          if (!_sameFolders(merged, remoteFolders) ||
              !_sameFolders(merged, local) ||
              !sameFolderOrder(mergedOrder, remoteOrder) ||
              !sameFolderOrder(mergedOrder, localOrder) ||
              !sameFolderColors(mergedColors, remoteColors) ||
              !sameFolderColors(mergedColors, localColorsNow) ||
              !sameNoteColors(mergedNoteColors, remoteNoteColors) ||
              !sameNoteColors(mergedNoteColors, localNoteColorsNow) ||
              (remoteCompact != null && mergedCompact != remoteCompact) ||
              mergedCompact != localCompactNow ||
              (remoteDefaultNote != null &&
                  mergedDefaultNote != remoteDefaultNote) ||
              mergedDefaultNote != localDefaultNoteNow ||
              (remoteFolderReported &&
                  mergedDefaultFolder != remoteDefaultFolder) ||
              mergedDefaultFolder != localDefaultFolderNow) {
            final confirmed = await _writeMeta(
              vault,
              name: serverMetadata[vault.id]?['name'] as String?,
              metadataBase: serverMetadata[vault.id],
              folders: merged,
              folderOrder: mergedOrder,
              folderColors: mergedColors,
              noteColors: mergedNoteColors,
              compactMode: mergedCompact,
              defaultNoteColor: mergedDefaultNote,
              defaultFolderColor: mergedDefaultFolder,
              offlineTolerant: true,
            );
            if (!confirmed) {
              // The local merge is durable, but the UI must not report a
              // successful synchronization while the server rejected metadata.
              throw StateError(
                tr(
                  'Nie udało się zsynchronizować folderów. Zmiany zachowano lokalnie.',
                  'Could not synchronize folders. Changes were kept locally.',
                ),
              );
            }
            if (unlocked.containsKey(vault.id)) {
              final name = serverMetadata[vault.id]?['name'] as String?;
              if (name != null) {
                _names[vault.id] = name;
                vault.name = name;
              }
            }
          } else if (storedBase == null ||
              !_sameFolders(storedBase, merged) ||
              !sameFolderOrder(baseOrder, mergedOrder) ||
              !sameFolderColors(baseColors, mergedColors) ||
              !sameNoteColors(baseNoteColors, mergedNoteColors) ||
              baseCompact != mergedCompact ||
              baseDefaultNote != mergedDefaultNote ||
              baseDefaultFolder != mergedDefaultFolder) {
            await _setFolderBase(
              vault,
              merged,
              order: mergedOrder,
              colors: mergedColors,
              compactMode: mergedCompact,
              noteColors: mergedNoteColors,
              defaultNoteColor: mergedDefaultNote,
              defaultFolderColor: mergedDefaultFolder,
            );
            storage.putVault(vault);
          }
        }
      });
      for (final v in vaults.where(
        (v) =>
            !vaultDeletionPending(v.id) &&
            v.syncEnabled &&
            v.owner == session!.owner &&
            unlocked.containsKey(v.id),
      )) {
        await serialized(() => _finishHiddenRemoteMoves(v));
        await serialized(() => _migrateHidden(v));
        await _push(v);
        var more = true;
        while (more) {
          final page = await api!.request(
            'GET',
            '/v1/vaults/${v.id}/changes?cursor=${storage.cursor(v.id)}',
          );
          await serialized(() async {
            for (final noteId in (page['purged'] as List? ?? const [])) {
              await _acceptPurge(v.id, noteId as String);
            }
            final incoming = <Revision>[];
            for (final item in page['revisions'] as List) {
              final j = item as Json;
              final r = Revision(
                id: j['id'] as String,
                vaultId: v.id,
                noteId: j['noteId'] as String,
                parents: (j['parents'] as List).cast<String>(),
                payload: j['payload'] as String,
                seq: j['seq'] as int,
              );
              if (_hiddenIdentity(v.id, r.noteId)) continue;
              final decoded = await _hiddenOuter(r);
              if (decoded['type'] == _HiddenSync.configKind) {
                await _rememberHiddenConfig(v.id, decoded['config'] as Json);
                incoming.add(r);
                continue;
              }
              if (decoded['type'] == _HiddenSync.kind) {
                await _acceptHidden(r, decoded);
                incoming.add(r);
                continue;
              }
              final plain = Note.fromJson(decoded);
              if (plain.id != r.noteId || plain.vaultId != v.id) {
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
              storage.setCursor(v.id, page['cursor'] as int);
            });
          });
          more = page['hasMore'] as bool;
        }
        await serialized(() => _reconcile(v));
        await _cacheImages(v);
        await _push(v);
      }
    } on ApiException catch (error) {
      final match = RegExp(r'^/v1/vaults/([a-fA-F0-9-]{36})(?:/|$)')
          .firstMatch(error.path ?? '');
      if (error.status == 410 &&
          match != null &&
          api == client &&
          session?.owner == owner) {
        await serialized(() => _acceptVaultTombstone(match.group(1)!, owner));
      } else {
        rethrow;
      }
    } finally {
      _syncing = false;
    }
  }

  Future<void> _push(Vault vault) async {
    // One durable batch per phase: typing during HTTP must not extend this
    // pass indefinitely. Remaining revisions stay pending for the next wakeup.
    var batch = storage.batch(vault.id);
    if (batch == null) {
      final pending = <Json>[];
      var size = 0;
      for (final revision in storage.pending(vault.id)) {
        final wire = revision.toWire();
        final outer = await _hiddenOuter(revision);
        final images = imageReferencePattern
            .allMatches(
              outer['type'] == _HiddenSync.kind ||
                      outer['type'] == _HiddenSync.configKind
                  ? ''
                  : Note.fromJson(outer).body,
            )
            .map((m) => m.group(1)!)
            .toSet()
            .toList();
        if (images.isNotEmpty) wire['images'] = images;
        final next = utf8.encode(jsonEncode(wire)).length;
        if (size + next > 3500000) break;
        pending.add(wire);
        size += next;
      }
      if (pending.isEmpty) return;
      // Persist the exact encrypted request BEFORE sending. Lost acknowledgements
      // retry the same bytes, revision IDs and batch ID across application restarts.
      batch = {'batchId': _uuid.v4(), 'revisions': pending};
      storage.putBatch(vault.id, batch);
    }
    await _uploadImages(vault);
    final response = await api!.request(
      'POST',
      '/v1/vaults/${vault.id}/batches',
      body: batch,
    );
    final ids = (batch['revisions'] as List)
        .map((r) => (r as Json)['id'] as String)
        .toList();
    final accepted = (response['accepted'] as List).cast<String>();
    if (response['batchId'] != batch['batchId'] ||
        ids.length != accepted.length ||
        !ids.every(accepted.contains)) {
      throw FormatException(
        tr(
          'Nieprawidłowe potwierdzenie synchronizacji.',
          'Invalid synchronization acknowledgment.',
        ),
      );
    }
    storage.atomic(() => storage.acknowledge(vault.id, ids));
  }

  Future<Note> _decode(Revision revision) async => Note.fromJson(
    jsonDecode(
      await crypto.openCompat(
        unlocked[revision.vaultId]!,
        revision.payload,
        revision.aad,
        revision.legacyAad,
      ),
    ) as Json,
  );
  ({String? id, bool ambiguous}) _ancestor(
    List<Revision> heads,
    List<Revision> all,
  ) {
    final byId = {for (final r in all) r.id: r};
    Set<String> ancestors(String start, {String? stopAt}) {
      final seen = <String>{}, queue = [start];
      while (queue.isNotEmpty) {
        final id = queue.removeLast();
        if (seen.add(id) && id != stopAt) {
          queue.addAll(byId[id]?.parents ?? []);
        }
      }
      return seen;
    }

    var common = ancestors(heads.first.id);
    for (final h in heads.skip(1)) {
      common = common.intersection(ancestors(h.id));
    }
    // A revision DAG can have several incomparable nearest common ancestors.
    // Neither SQLite order nor an older shared ancestor is an authoritative
    // merge base: the latter can erase a deliberate restore to old/empty text
    // through threeWayMerge's unchanged-side shortcut. Keep that ambiguity
    // explicit so reconciliation preserves the distinct head documents.
    final parents = common
        .expand((id) => byId[id]?.parents ?? <String>[])
        .toSet();
    final nearest = common.difference(parents);
    // Missing records are still ancestry candidates: filtering them earlier
    // could promote an older known record into a false authoritative base.
    // A missing or absent base is not evidence that its body was empty.
    final id = nearest.singleOrNull;
    // A missing path need not survive the common-ancestor intersection: it can
    // conceal a newer common base. Require complete paths down to the chosen
    // candidate, without requiring history older than that authoritative base.
    final trusted =
        id != null &&
        byId.containsKey(id) &&
        heads.every(
          (head) => ancestors(head.id, stopAt: id).every(byId.containsKey),
        );
    return (id: trusted ? id : null, ambiguous: !trusted);
  }

  Future<void> _reconcile(Vault vault) async {
    final all = storage.revisions(vault.id);
    for (final noteId in all.map((r) => r.noteId).toSet()) {
      final first = all.firstWhere((r) => r.noteId == noteId);
      final type = (await _hiddenOuter(first))['type'];
      if (type == _HiddenSync.configKind) continue;
      if (type == _HiddenSync.kind) {
        await _projectHidden(vault, noteId);
        continue;
      }
      if (_hiddenIdentity(vault.id, noteId)) {
        await _eraseNote(vault.id, noteId);
        continue;
      }
      final branches = heads(vault.id, noteId);
      if (branches.isEmpty) continue;
      if (branches.length == 1) {
        final doc = await _decode(branches.single);
        await _document(doc, [branches.single.id]);
        await _mirror(doc);
        continue;
      }
      final documents = await Future.wait(branches.map(_decode));
      // Two devices may independently resolve the same branches. Their encrypted
      // revisions have distinct IDs/nonces, but do not need another merge when
      // they represent the same document. Keep every head as parents of the next
      // real edit instead of producing an endless merge-of-merges ping-pong.
      if (documents.every((n) => _sameContent(n, documents.first))) {
        await _document(documents.first, branches.map((r) => r.id).toList());
        await _mirror(documents.first);
        continue;
      }
      final ancestor = _ancestor(branches, all);
      final base = ancestor.id == null
          ? null
          : await _decode(all.firstWhere((r) => r.id == ancestor.id));
      var result = documents.first;
      final conflicts = <({Note note, String revision})>[];
      for (var i = 1; i < documents.length; i++) {
        final next = documents[i];
        if (result.deleted && !next.deleted) {
          result = next;
          continue;
        }
        if (next.deleted && !result.deleted) continue;
        final merge = threeWayMerge(base?.body ?? '', result.body, next.body);
        final titleConflict =
            base != null &&
            result.title != base.title &&
            next.title != base.title &&
            result.title != next.title;
        if (ancestor.ambiguous || merge.conflict || titleConflict) {
          conflicts.add((note: next, revision: branches[i].id));
        } else {
          result = result.copyWith(
            body: merge.text,
            title: base != null && result.title == base.title
                ? next.title
                : result.title,
          );
        }
      }
      // Conflicting versions become normal encrypted notes with deterministic IDs.
      // Every branch remains in immutable history even after a merge or deletion.
      for (final conflict in conflicts) {
        final copyId = await crypto.stableId(
          unlocked[vault.id]!,
          'conflict:$noteId:${conflict.revision}',
        );
        if (notes[vault.id]?.containsKey(copyId) == true) continue;
        final n = conflict.note;
        final copy = Note(
          id: copyId,
          vaultId: vault.id,
          // Persist the legacy suffix: this deterministic ID must have the same
          // content on every client, independently of its interface language.
          title: '${n.title} (kopia konfliktowa)',
          body: n.body,
          folder: n.folder,
          createdAt: n.createdAt,
          updatedAt: n.updatedAt,
          conflict: true,
        );
        final rev = await _makeRevision(copy, []);
        storage.putRevision(rev, pending: true);
        await _document(copy, [rev.id]);
        await _mirror(copy);
      }
      final rev = await _makeRevision(
        result,
        branches.map((r) => r.id).toList(),
      );
      storage.putRevision(rev, pending: true);
      await _document(result, [rev.id]);
      await _mirror(result);
    }
  }

  // ---- Hidden notes -------------------------------------------------------
  /// Hidden plaintext stays in a separate password-encrypted store. Synced
  /// vaults transport only a doubly encrypted revision; account keys alone
  /// cannot decrypt the note or its user metadata.
  static const _hiddenSaltSlot = 'silique.hidden.salt';
  static const _hiddenWrapSlot = 'silique.hidden.wrap';
  static const _hiddenCheckSlot = 'silique.hidden.check';
  static const _hiddenAutoLockSlot = 'silique.hidden.autoLock';
  static const _hiddenBackgroundSlot = 'silique.hidden.lockOnBackground';
  static const hiddenVaultPrefix = 'hidden:';

  final _hiddenStateChanges = StreamController<void>.broadcast(sync: true);
  Stream<void> get hiddenStateChanges => _hiddenStateChanges.stream;
  List<int>? _hiddenKey;
  final _hiddenKeys = <String, List<int>>{};
  Json? _hiddenActiveConfig;
  Timer? _hiddenAutoLockTimer;
  DateTime? _hiddenActivity;
  bool _hiddenLockOnBackground = true;

  bool get hiddenPasswordSet =>
      _hiddenPasswordSalt != null ||
      vaults.any((v) => storage.documents(_hiddenConfigs(v.id)).isNotEmpty);
  String? _hiddenPasswordSalt;
  bool _hiddenLockRequested = false;
  int _hiddenGeneration = 0;
  bool get _hiddenExpired =>
      _hiddenAutoLock != null &&
      _hiddenActivity != null &&
      DateTime.now().difference(_hiddenActivity!) >= _hiddenAutoLock!;
  bool get hiddenUnlocked =>
      _hiddenKey != null && !_hiddenLockRequested && !_hiddenExpired;

  /// Minutes of inactivity after which the hidden store locks itself.
  /// `null` disables the timer; closing the app always locks it.
  Duration? get hiddenAutoLock => _hiddenAutoLock;
  Duration? _hiddenAutoLock;

  bool get hiddenLockOnBackground => _hiddenLockOnBackground;

  String _hiddenVault(String vaultId) => '$hiddenVaultPrefix$vaultId';
  String _hiddenRetiredVault(String vaultId) => 'hidden-retired:$vaultId';
  bool _hiddenIdentity(String vaultId, String noteId) =>
      storage.documents(_hiddenVault(vaultId)).containsKey(noteId) ||
      storage.documents(_hiddenRetiredVault(vaultId)).containsKey(noteId);

  // An encrypted recovery copy is also a durable move intent. A crash or lost
  // DELETE acknowledgement retries the idempotent purge, never the old upload.
  Future<void> _finishHiddenRemoteMoves(Vault vault) async {
    final retired = storage.documents(_hiddenRetiredVault(vault.id));
    for (final id in storage.documents(_hiddenVault(vault.id)).keys) {
      if (retired.containsKey(id)) continue;
      // Only legacy ciphertext or a staged ordinary-to-hidden move needs
      // the old ID purged. Preserve the purge intent across local edits and
      // migration, which replace the encrypted hidden index.
      final info = await _hiddenInfo(vault.id, id);
      if (info != null &&
          info['unmigrated'] != true &&
          info['ordinaryPurgePending'] != true) {
        continue;
      }
      final response = await api!.request(
        'DELETE',
        '/v1/vaults/${vault.id}/notes/$id',
      );
      if (response['purged'] != true) {
        throw FormatException(
          tr(
            'Serwer nie potwierdził usunięcia notatki.',
            'The server did not confirm deletion of the note.',
          ),
        );
      }
      storage.putDocument(_hiddenRetiredVault(vault.id), id, '1');
    }
  }

  Future<void> loadHiddenSettings() async {
    _hiddenPasswordSalt = await keys.read(_hiddenSaltSlot);
    final seconds = await keys.read(_hiddenAutoLockSlot);
    _hiddenAutoLock = seconds == 'off'
        ? null
        : Duration(seconds: int.tryParse(seconds ?? '') ?? 300);
    _hiddenLockOnBackground =
        (await keys.read(_hiddenBackgroundSlot)) != 'false';
  }

  Future<void> setHiddenAutoLock(Duration? after) => _operation(
    () => _setHiddenAutoLock(after),
    failureKey: 'hidden-auto-lock',
  );
  Future<void> _setHiddenAutoLock(Duration? after) async {
    if (after != null && after <= Duration.zero) {
      throw ArgumentError.value(after, 'after');
    }
    _hiddenAutoLock = after;
    await keys.write(
      _hiddenAutoLockSlot,
      after == null ? 'off' : '${after.inSeconds}',
    );
    _scheduleHiddenAutoLock();
  }

  Future<void> setHiddenLockOnBackground(bool value) => _operation(
    () => _setHiddenLockOnBackground(value),
    failureKey: 'hidden-background',
  );
  Future<void> _setHiddenLockOnBackground(bool value) async {
    _hiddenLockOnBackground = value;
    await keys.write(_hiddenBackgroundSlot, value ? 'true' : 'false');
  }

  Future<List<int>> _hiddenKeyFor(String password) async {
    final salt = base64Decode(_hiddenPasswordSalt!);
    final wrapping = await crypto.passwordKey(password, salt);
    final wrapped = await keys.read(_hiddenWrapSlot);
    if (wrapped == null) {
      throw StateError(
        tr('Brak klucza ukrytych notatek.', 'The hidden notes key is missing.'),
      );
    }
    return base64Decode(
      await crypto.open(wrapping, wrapped, 'silique:1:hidden-key'),
    );
  }

  /// Creates the hidden-note password. Only the first hidden note needs this.
  Future<void> setHiddenPassword(String password) {
    final generation = _hiddenGeneration;
    return serialized(() async {
      if (password.trim().length < 8) {
        throw FormatException(
          tr(
            'Hasło musi mieć co najmniej 8 znaków.',
            'The password must contain at least 8 characters.',
          ),
        );
      }
      if (hiddenPasswordSet) {
        throw StateError(
          tr(
            'Hasło ukrytych notatek istnieje.',
            'A hidden notes password is already set.',
          ),
        );
      }
      final salt = crypto.randomKey().sublist(0, 16);
      final wrapping = await crypto.passwordKey(password, salt);
      final hiddenKey = crypto.randomKey();
      await keys.write(
        _hiddenWrapSlot,
        await crypto.seal(
          wrapping,
          base64Encode(hiddenKey),
          'silique:1:hidden-key',
        ),
      );
      await keys.write(
        _hiddenCheckSlot,
        await crypto.seal(
          hiddenKey,
          'silique-hidden-v1',
          'silique:1:hidden-check',
        ),
      );
      // Commit marker last. An interrupted first setup can be retried safely.
      await keys.write(_hiddenSaltSlot, base64Encode(salt));
      _hiddenPasswordSalt = base64Encode(salt);
      final config = await _localHiddenConfig();
      if (generation != _hiddenGeneration) {
        hiddenKey.fillRange(0, hiddenKey.length, 0);
        return;
      }
      _hiddenKey = hiddenKey;
      _hiddenKeys[config['id'] as String] = hiddenKey;
      _hiddenActiveConfig = config;
      _localChanges.add(null);
      _hiddenLockRequested = false;
      _hiddenActivity = DateTime.now();
      _hiddenStateChanges.add(null);
      hiddenActivity();
    });
  }

  Future<bool> unlockHidden(String password) {
    final generation = _hiddenGeneration;
    return serialized(() async {
      if (!hiddenPasswordSet) {
        throw StateError(
          tr(
            'Najpierw ustaw hasło ukrytych notatek.',
            'Set a hidden notes password first.',
          ),
        );
      }
      final candidates = await _unlockPortableHidden(password);
      if (_hiddenPasswordSalt != null) {
        final config = await _localHiddenConfig();
        try {
          final key = await _hiddenKeyFor(password);
          await crypto.open(
            key,
            config['check'] as String,
            'silique:1:hidden-check',
          );
          candidates[config['id'] as String] = (key: key, config: config);
        } on SecretBoxAuthenticationError {
          // A remote password domain must not replace local credentials.
        }
      }
      if (candidates.isEmpty) return false;
      if (generation != _hiddenGeneration) {
        for (final candidate in candidates.values) {
          candidate.key.fillRange(0, candidate.key.length, 0);
        }
        return false;
      }
      final selected = candidates.values.first;
      if (_hiddenPasswordSalt == null) {
        await keys.write(_hiddenWrapSlot, selected.config['wrap'] as String);
        await keys.write(_hiddenCheckSlot, selected.config['check'] as String);
        await keys.write(_hiddenSaltSlot, selected.config['salt'] as String);
        _hiddenPasswordSalt = selected.config['salt'] as String;
      }
      if (generation != _hiddenGeneration) {
        for (final candidate in candidates.values) {
          candidate.key.fillRange(0, candidate.key.length, 0);
        }
        return false;
      }
      // A new unlock replaces, rather than accumulates, password domains.
      for (final key in _hiddenKeys.values) {
        key.fillRange(0, key.length, 0);
      }
      _hiddenKeys.clear();
      _hiddenKeys.addAll(candidates.map((id, c) => MapEntry(id, c.key)));
      _hiddenKey = selected.key;
      _hiddenActiveConfig = selected.config;
      _hiddenLockRequested = false;
      _hiddenActivity = DateTime.now();
      _hiddenStateChanges.add(null);
      hiddenActivity();
      return true;
    });
  }

  void hiddenActivity() {
    if (_hiddenKey == null || _hiddenLockRequested) return;
    if (_hiddenExpired) {
      unawaited(lockHidden());
      return;
    }
    _hiddenActivity = DateTime.now();
    _scheduleHiddenAutoLock();
  }

  void _scheduleHiddenAutoLock() {
    _hiddenAutoLockTimer?.cancel();
    final after = _hiddenAutoLock;
    if (_hiddenKey == null || after == null) return;
    _hiddenAutoLockTimer = Timer(after, () {
      final last = _hiddenActivity;
      if (last != null && DateTime.now().difference(last) < after) {
        _scheduleHiddenAutoLock();
        return;
      }
      lockHidden();
    });
  }

  /// Forgets the hidden key. Content stays encrypted on disk.
  Future<void> lockHidden() {
    _hiddenGeneration++;
    _hiddenLockRequested = true;
    _hiddenAutoLockTimer?.cancel();
    _hiddenAutoLockTimer = null;
    // Cover plaintext immediately; the queued commit still drains edits captured
    // before the lock request before forgetting their encryption key.
    if (!_hiddenStateChanges.isClosed) _hiddenStateChanges.add(null);
    // Key revocation is allowed while fenced; it writes no persistent data.
    return _enqueue(() async {
      final key = _hiddenKey;
      if (key != null) key.fillRange(0, key.length, 0);
      _hiddenKey = null;
      for (final other in _hiddenKeys.values) {
        other.fillRange(0, other.length, 0);
      }
      _hiddenKeys.clear();
      _hiddenActiveConfig = null;
      _hiddenActivity = null;
    });
  }

  /// Seals [note] with the hidden key and removes its plaintext copy, history
  /// and Markdown mirror from the vault.
  Future<void> hideNote(Note note) => _operation(
    () => _hideNote(note),
    failureKey: ('hide', note.vaultId, note.id),
  );
  Future<void> _hideNote(Note note) async {
    final generation = _hiddenGeneration;
    if (!hiddenUnlocked) {
      throw StateError(
        tr('Najpierw odblokuj ukryte notatki.', 'Unlock hidden notes first.'),
      );
    }
    if (_syncing) {
      throw StateError(
        tr(
          'Poczekaj na zakończenie synchronizacji.',
          'Wait for synchronization to finish.',
        ),
      );
    }
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    if (vault.owner != null) {
      if (!vault.syncEnabled ||
          session?.owner != vault.owner ||
          api == null ||
          accountKey == null) {
        throw StateError(
          tr(
            'Połącz konto właściciela i włącz synchronizację przed przeniesieniem do ukrytych notatek.',
            'Connect the owner\'s account and enable synchronization before moving to hidden notes.',
          ),
        );
      }
      // Drain a previously persisted batch unchanged before retiring its note ID.
      await sync();
    }
    await serialized(() async {
      if (_syncing) {
        throw StateError(
          tr(
            'Poczekaj na zakończenie synchronizacji.',
            'Wait for synchronization to finish.',
          ),
        );
      }
      if (storage.batch(vault.id) != null ||
          storage.pending(vault.id).isNotEmpty && vault.owner != null) {
        throw StateError(
          tr(
            'Dokończ synchronizację oczekujących zmian i spróbuj ponownie.',
            'Finish synchronizing pending changes and try again.',
          ),
        );
      }
      final key = _hiddenKey;
      if (key == null ||
          !hiddenUnlocked ||
          generation != _hiddenGeneration ||
          !unlocked.containsKey(vault.id)) {
        throw StateError(
          tr('Najpierw odblokuj notatki.', 'Unlock the notes first.'),
        );
      }
      _hiddenMoving = true;
      try {
        final current = notes[vault.id]?[note.id];
        if (current == null || current.deleted) {
          throw StateError(
            tr('Notatka nie jest dostępna.', 'The note is unavailable.'),
          );
        }
        final embedded = await noteWithEmbeddedImages(current);
        final hidden = embedded.copyWith(hidden: true);
        final sealed = await crypto.seal(
          key,
          jsonEncode(hidden.toJson()),
          'silique:1:hidden:${note.vaultId}:${note.id}',
        );
        if (!hiddenUnlocked ||
            generation != _hiddenGeneration ||
            !identical(_hiddenKey, key) ||
            !unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj notatki.', 'Unlock the notes first.'),
          );
        }
        final stagedIdentity = await _stageHiddenIdentity(
          vault.id,
          note.id,
          retiringOrdinary: true,
        );
        if (!hiddenUnlocked ||
            generation != _hiddenGeneration ||
            !identical(_hiddenKey, key) ||
            !unlocked.containsKey(vault.id)) {
          throw StateError(
            tr('Najpierw odblokuj notatki.', 'Unlock the notes first.'),
          );
        }
        storage.putDocument(_hiddenIndex(vault.id), note.id, stagedIdentity);
        // Persist the recovery copy before any destructive operation. Never
        // claim that other devices are protected until the server confirms purge.
        if (vault.owner != null) {
          storage.putDocument(_hiddenVault(vault.id), note.id, sealed);
          try {
            final response = await api!.request(
              'DELETE',
              '/v1/vaults/${vault.id}/notes/${note.id}',
            );
            if (response['purged'] != true) {
              throw FormatException(
                tr(
                  'Serwer nie potwierdził usunięcia notatki.',
                  'The server did not confirm deletion of the note.',
                ),
              );
            }
            storage.putDocument(_hiddenRetiredVault(vault.id), note.id, '1');
          } on ApiException catch (error) {
            if (error.status >= 400 && error.status < 500) {
              // Definite refusal: no remote deletion took place.
              storage.removeDocument(_hiddenVault(vault.id), note.id);
              storage.removeDocument(_hiddenIndex(vault.id), note.id);
            } else {
              await _eraseNote(vault.id, note.id, hiddenDocument: sealed);
            }
            rethrow;
          } catch (_) {
            // Outcome unknown: keep the encrypted copy and retire locally.
            await _eraseNote(vault.id, note.id, hiddenDocument: sealed);
            rethrow;
          }
        }
        await _eraseNote(vault.id, note.id, hiddenDocument: sealed);
        hiddenActivity();
        _localChanges.add(null);
      } finally {
        _hiddenMoving = false;
      }
    });
  }

  Future<void> _saveHidden(
    Note note, {
    bool creating = false,
    List<int>? capturedKey,
  }) async {
    _requireLiveVault(note.vaultId);
    if (!creating &&
        !storage.documents(_hiddenVault(note.vaultId)).containsKey(note.id)) {
      throw StateError(
        tr('Nie znaleziono ukrytej notatki.', 'Hidden note not found.'),
      );
    }
    if (storage.documents(note.vaultId).containsKey(note.id)) {
      throw StateError(
        tr(
          'Przenieś zwykłą notatkę do ukrytych zamiast zmieniać jej znacznik.',
          'Move the ordinary note to hidden notes instead of changing its flag.',
        ),
      );
    }
    final key = capturedKey ?? _hiddenKey;
    if (key == null ||
        !identical(_hiddenKey, key) ||
        (capturedKey == null && !hiddenUnlocked)) {
      throw StateError(
        tr('Ukryte notatki są zablokowane.', 'Hidden notes are locked.'),
      );
    }
    if (!unlocked.containsKey(note.vaultId)) {
      throw StateError(tr('Vault jest zablokowany.', 'The vault is locked.'));
    }
    final noteKey = creating ? key : await _keyForHidden(note.vaultId, note.id);
    if (noteKey == null) {
      throw StateError(
        tr(
          'Odblokuj hasło tej ukrytej notatki.',
          'Unlock this hidden note with its password.',
        ),
      );
    }
    final sealed = await crypto.seal(
      noteKey,
      jsonEncode(note.toJson()),
      'silique:1:hidden:${note.vaultId}:${note.id}',
    );
    if (!identical(_hiddenKey, key) ||
        (capturedKey == null && !hiddenUnlocked) ||
        !unlocked.containsKey(note.vaultId)) {
      throw StateError(
        tr('Ukryte notatki są zablokowane.', 'Hidden notes are locked.'),
      );
    }
    final vault = vaults.firstWhere((v) => v.id == note.vaultId);
    final sync = vault.owner != null || vault.syncEnabled
        ? await _prepareHiddenRevision(note, sealed)
        : null;
    final staged = sync == null && creating
        ? await _stageHiddenIdentity(note.vaultId, note.id)
        : null;
    storage.atomic(() {
      if (!identical(_hiddenKey, key) ||
          (capturedKey == null && !hiddenUnlocked) ||
          !unlocked.containsKey(note.vaultId)) {
        throw StateError(
          tr('Ukryte notatki są zablokowane.', 'Hidden notes are locked.'),
        );
      }
      if (staged != null) {
        storage.putDocument(_hiddenIndex(note.vaultId), note.id, staged);
      }
      if (sync != null) {
        storage.putDocument(_hiddenIndex(note.vaultId), note.id, sync.index);
        storage.putRevision(sync.revision, pending: true);
      }
      storage.putDocument(_hiddenVault(note.vaultId), note.id, sealed);
      if (creating) {
        // A freshly created local secret has no remote identity to purge.
        storage.putDocument(
          _hiddenRetiredVault(note.vaultId),
          note.id,
          'local',
        );
      }
    });
    hiddenActivity();
    _localChanges.add(null);
  }

  Future<Note> createHiddenNote(String vaultId) => serialized(() async {
    final now = DateTime.now().toUtc();
    final note = Note(
      id: _uuid.v4(),
      vaultId: vaultId,
      title: tr('Bez tytułu', 'Untitled'),
      body: '',
      createdAt: now,
      updatedAt: now,
      hidden: true,
    );
    await _saveHidden(note, creating: true);
    return note;
  });

  /// Hidden notes of [vaultId], decrypted in memory. Empty while locked.
  Future<List<Note>> hiddenNotes(String vaultId) => serialized(() async {
    if (vaultDeletionPending(vaultId) || storage.isVaultDeleted(vaultId)) {
      return const [];
    }
    final key = _hiddenKey;
    if (!hiddenUnlocked || key == null || !unlocked.containsKey(vaultId)) {
      return const [];
    }
    await _refreshHidden(vaultId);
    final found = <Note>[];
    for (final entry in storage.documents(_hiddenVault(vaultId)).entries) {
      final noteKey = await _keyForHidden(vaultId, entry.key);
      if (noteKey == null) continue;
      final plain = await crypto.open(
        noteKey,
        entry.value,
        'silique:1:hidden:$vaultId:${entry.key}',
      );
      final note = Note.fromJson(jsonDecode(plain) as Json);
      if (note.id != entry.key || note.vaultId != vaultId || !note.hidden) {
        throw FormatException(
          tr(
            'Niezgodna tożsamość ukrytej notatki.',
            'Hidden note identity mismatch.',
          ),
        );
      }
      if (!note.deleted) found.add(note);
    }
    if (!hiddenUnlocked) return const [];
    found.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return found;
  });

  /// Permanently deletes a hidden note. For a synced vault the opaque wire ID
  /// is purged on the server before removing the local encrypted copy; a failed
  /// acknowledgement leaves the copy available for a safe retry.
  Future<void> deleteHiddenNote(String vaultId, String noteId) => _operation(
    () => _deleteHiddenNote(vaultId, noteId),
    failureKey: ('delete-hidden', vaultId, noteId),
  );
  Future<void> _deleteHiddenNote(String vaultId, String noteId) async {
    final generation = _hiddenGeneration;
    final vault = vaults.firstWhere((v) => v.id == vaultId);
    if (vault.owner != null) {
      if (!vault.syncEnabled ||
          session?.owner != vault.owner ||
          api == null ||
          accountKey == null) {
        throw StateError(
          tr(
            'Połącz konto właściciela i włącz synchronizację.',
            'Connect the owner\'s account and enable synchronization.',
          ),
        );
      }
      if (_syncing) {
        throw StateError(
          tr(
            'Poczekaj na zakończenie synchronizacji.',
            'Wait for synchronization to finish.',
          ),
        );
      }
      // Drain a persisted batch before retiring its wire identity. Otherwise a
      // lost acknowledgement could replay an older encrypted edit after purge.
      await sync();
    }
    await serialized(() async {
      if (generation != _hiddenGeneration ||
          !hiddenUnlocked ||
          !unlocked.containsKey(vaultId)) {
        throw StateError(
          tr(
            'Najpierw odblokuj ukryte notatki i vault.',
            'Unlock hidden notes and the vault first.',
          ),
        );
      }
      final sealed = storage.documents(_hiddenVault(vaultId))[noteId];
      if (sealed == null) {
        throw StateError(
          tr('Nie znaleziono ukrytej notatki.', 'Hidden note not found.'),
        );
      }
      final key = await _keyForHidden(vaultId, noteId);
      if (key == null) {
        throw StateError(
          tr(
            'Odblokuj hasło tej ukrytej notatki.',
            'Unlock this hidden note with its password.',
          ),
        );
      }
      final plain = Note.fromJson(
        jsonDecode(
          await crypto.open(key, sealed, 'silique:1:hidden:$vaultId:$noteId'),
        ) as Json,
      );
      if (plain.id != noteId || plain.vaultId != vaultId || !plain.hidden) {
        throw FormatException(
          tr(
            'Niezgodna tożsamość ukrytej notatki.',
            'Hidden note identity mismatch.',
          ),
        );
      }
      if (generation != _hiddenGeneration ||
          !hiddenUnlocked ||
          !unlocked.containsKey(vaultId)) {
        throw StateError(
          tr(
            'Najpierw odblokuj ukryte notatki i vault.',
            'Unlock hidden notes and the vault first.',
          ),
        );
      }
      if (vault.owner != null) {
        if (_syncing ||
            session?.owner != vault.owner ||
            api == null ||
            storage.batch(vaultId) != null ||
            storage.pending(vaultId).isNotEmpty) {
          throw StateError(
            tr(
              'Dokończ synchronizację oczekujących zmian i spróbuj ponownie.',
              'Finish synchronizing pending changes and try again.',
            ),
          );
        }
        final info = await _hiddenInfo(vaultId, noteId);
        if (info == null || info['unmigrated'] == true) {
          throw StateError(
            tr(
              'Dokończ synchronizację ukrytej notatki.',
              'Finish synchronizing the hidden note.',
            ),
          );
        }
        final wireId = info['wire'] as String;
        if (generation != _hiddenGeneration ||
            !hiddenUnlocked ||
            !unlocked.containsKey(vaultId) ||
            session?.owner != vault.owner ||
            api == null) {
          throw StateError(
            tr(
              'Najpierw odblokuj ukryte notatki i vault.',
              'Unlock hidden notes and the vault first.',
            ),
          );
        }
        _hiddenMoving = true;
        try {
          final response = await api!.request(
            'DELETE',
            '/v1/vaults/$vaultId/notes/$wireId',
          );
          if (response['purged'] != true) {
            throw FormatException(
              tr(
                'Brak potwierdzenia usunięcia.',
                'Deletion was not acknowledged.',
              ),
            );
          }
          await _acceptPurge(vaultId, wireId);
        } finally {
          _hiddenMoving = false;
        }
      } else {
        storage.atomic(() {
          // Keep a local identity tombstone after deleting ciphertext. A stale
          // ordinary editor must not recreate the former plaintext note.
          storage.putDocument(_hiddenRetiredVault(vaultId), noteId, 'local');
          storage.removeDocument(_hiddenVault(vaultId), noteId);
          storage.removeDocument(_hiddenIndex(vaultId), noteId);
        });
      }
      _localChanges.add(null);
    });
  }

  /// Moves a hidden note back into its vault, decrypted and editable.
  /// [folder] overrides the original location; an empty string means root.
  Future<Note> unhideNote(String vaultId, String noteId, {String? folder}) {
    final destinationFolder = folder == null
        ? null
        : folder.trim().isEmpty
        ? ''
        : normalizeFolderPath(folder);
    if (folder != null && destinationFolder == null) {
      return Future.error(
        FormatException(
          folderPathError(folder) ??
              tr('Nieprawidłowa ścieżka folderu.', 'Invalid folder path.'),
        ),
      );
    }
    final generation = _hiddenGeneration;
    void validateReveal() {
      if (generation != _hiddenGeneration || !hiddenUnlocked) {
        throw StateError(
          tr('Najpierw odblokuj ukryte notatki.', 'Unlock hidden notes first.'),
        );
      }
      if (!unlocked.containsKey(vaultId)) {
        throw StateError(tr('Vault jest zablokowany.', 'The vault is locked.'));
      }
    }

    return serialized(() async {
      validateReveal();
      final key = await _keyForHidden(vaultId, noteId);
      if (key == null) {
        throw StateError(
          tr(
            'Odblokuj hasło tej ukrytej notatki.',
            'Unlock this hidden note with its password.',
          ),
        );
      }
      final sealed = storage.documents(_hiddenVault(vaultId))[noteId];
      if (sealed == null) {
        throw StateError(
          tr('Nie znaleziono ukrytej notatki.', 'Hidden note not found.'),
        );
      }
      final plain = Note.fromJson(
        jsonDecode(
          await crypto.open(key, sealed, 'silique:1:hidden:$vaultId:$noteId'),
        ) as Json,
      );
      if (plain.id != noteId || plain.vaultId != vaultId || !plain.hidden) {
        throw FormatException(
          tr(
            'Niezgodna tożsamość ukrytej notatki.',
            'Hidden note identity mismatch.',
          ),
        );
      }
      final destination = vaults.firstWhere((v) => v.id == vaultId);
      if (destination.owner != null &&
          !storage
              .documents(_hiddenRetiredVault(vaultId))
              .containsKey(noteId)) {
        if (_syncing || api == null || session?.owner != destination.owner) {
          throw StateError(
            tr(
              'Połącz konto, aby dokończyć przenoszenie notatki.',
              'Connect an account to finish moving the note.',
            ),
          );
        }
        _hiddenMoving = true;
        try {
          await _finishHiddenRemoteMoves(destination);
        } finally {
          _hiddenMoving = false;
        }
      }
      var restored = Note(
        id: destination.owner == null ? plain.id : _uuid.v4(),
        vaultId: vaultId,
        title: plain.title,
        body: plain.body,
        folder: destinationFolder ?? plain.folder,
        createdAt: plain.createdAt,
        updatedAt: DateTime.now().toUtc(),
        journalDate: plain.journalDate,
        tags: plain.tags,
        favorite: plain.favorite,
        conflict: plain.conflict,
      );
      // Restore large photographs as ordinary encrypted chunked assets rather
      // than forcing their base64 bytes through the 1 MB text revision limit.
      final prepared = <String, _PreparedImage>{};
      final embedded = RegExp(
        r'data:(image/(?:png|jpeg|gif|webp|bmp));base64,([A-Za-z0-9+/=]+)',
      );
      for (final match in embedded.allMatches(restored.body)) {
        final uri = match.group(0)!;
        if (prepared.containsKey(uri)) continue;
        prepared[uri] = await _prepareImage(
          vaultId,
          restored.id,
          base64Decode(match.group(2)!),
          match.group(1)!,
        );
      }
      var body = restored.body;
      for (final item in prepared.entries) {
        body = body.replaceAll(item.key, 'silique-image:${item.value.id}');
      }
      if (body != restored.body) restored = restored.copyWith(body: body);
      final info = await _hiddenInfo(vaultId, noteId);
      final retirement = info == null || info['unmigrated'] == true
          ? null
          : await _hiddenRevision(
              vaultId,
              info['wire'] as String,
              noteId,
              sealed,
              await _hiddenConfig(vaultId, info['config'] as String),
              heads(vaultId, info['wire'] as String).map((r) => r.id).toList(),
              retired: true,
            );
      await _saveNote(
        restored,
        revealing: true,
        validateCommit: validateReveal,
        withinCommit: () {
          if (retirement != null) {
            storage.putRevision(retirement, pending: true);
          }
          for (final image in prepared.values) {
            _storePreparedImage(vaultId, image);
          }
          storage.removeDocument(_hiddenVault(vaultId), noteId);
          if (retirement == null) {
            storage.removeDocument(_hiddenIndex(vaultId), noteId);
          }
          if (restored.id == noteId) {
            storage.removeDocument(_hiddenRetiredVault(vaultId), noteId);
          }
        },
      );
      hiddenActivity();
      _localChanges.add(null);
      return restored;
    });
  }

  Future<void> close() async {
    await lockHidden();
    await _tail;
    await _localChanges.close();
    await _accessChanges.close();
    await _hiddenStateChanges.close();
    await _vaultDeletions.close();
    api?.close();
    await storage.close();
  }
}

/// Decodes the compact-mode flag stored beside `folderOrder` in the encrypted
/// vault metadata; anything but a literal `true` (including an absent key or a
/// value written by an older client) means the preference is off.
bool decodeCompactMode(Object? raw) => raw == true;

/// Three-way merge of the compact-mode flag against its confirmed base:
/// a server-confirmed change wins, otherwise the local preference stands —
/// the single-value counterpart of [mergeFolderColors].
bool mergeCompactMode({
  required bool base,
  required bool local,
  required bool server,
}) => server != base ? server : local;

/// Decodes a single optional 32-bit ARGB color preference (`defaultNoteColor`
/// or `defaultFolderColor`); `null` when absent, invalid or not an int. The
/// `kDefaultNoteColor` fallback is applied by the note getter, not here, so the
/// stored/merged value stays faithful to "unset".
int? decodeDefaultColor(Object? raw) =>
    raw is int && raw >= 0 && raw <= 0xFFFFFFFF ? raw : null;

/// Three-way merge of a single optional color value, mirroring
/// [mergeCompactMode]: a server-confirmed change wins, otherwise the local
/// value stands. `null` means "no color" (or "unset") and is a legitimate
/// result.
int? mergeDefaultColor({
  required int? base,
  required int? local,
  required int? server,
}) => server != base ? server : local;
