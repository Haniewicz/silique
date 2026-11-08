import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/credential_mode.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' hide Session;
import 'package:silique/storage/native_storage.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/storage/startup_notebook.dart';
import 'package:silique/storage/native_crypto.dart';
import 'package:silique/storage/managed_keys.dart';
import 'package:silique/storage/credential_files.dart';

class Keys implements KeyStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class GatedKeys extends Keys implements CredentialModeControl {
  Completer<void>? entered, release;
  @override
  CredentialMode mode = CredentialMode.local;
  @override
  bool get cleanupPending => false;
  Future<void> gate() async {
    entered?.complete();
    await release?.future;
  }

  @override
  Future<void> write(String key, String value) async {
    await gate();
    await super.write(key, value);
  }

  @override
  Future<void> changeMode(CredentialMode value) async {
    await gate();
    mode = value;
  }

  @override
  Future<void> retryCleanup() => gate();
}

class GatedCrypto extends NativeCrypto {
  Completer<void>? entered, release;
  @override
  Future<String> stableId(List<int> key, String value) async {
    if (value.startsWith('journal:')) {
      entered?.complete();
      await release?.future;
    }
    return super.stableId(key, value);
  }
}

class GatedSyncNotebook extends Notebook {
  GatedSyncNotebook({required super.storage, required super.keys})
    : super(crypto: NativeCrypto());
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<void> sync() async {
    entered.complete();
    await release.future;
  }
}

class SystemKeys extends Keys implements SystemCredentialBackend {
  Completer<void>? entered, release;
  @override
  Future<Map<String, String>> snapshot() async {
    final start = entered;
    if (start != null && !start.isCompleted) {
      start.complete();
      await release!.future;
    }
    return {...values};
  }

  @override
  Future<void> replace(Map<String, String> values) async {
    this.values
      ..clear()
      ..addAll(values);
  }

  @override
  Future<void> clear() async => values.clear();
}

class GatedIntentStorage extends NativeStorage {
  GatedIntentStorage(super.root);
  Completer<void>? entered, release;
  @override
  Future<Map<String, String>> deletionIntents() async {
    final start = entered;
    if (start != null && !start.isCompleted) {
      start.complete();
      await release!.future;
    }
    return super.deletionIntents();
  }
}

void main() {
  test(
    'final admitted flush acknowledges retry of the same failed edit',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-update-flush-retry-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys());
      await repo.createVault('Synthetic');
      final note = await repo.createNote(repo.vaults.single.id);
      final storage = repo.storage as NativeStorage;
      storage.db.execute('PRAGMA query_only=ON');
      await expectLater(
        repo.save(note.copyWith(body: 'retry me')),
        throwsA(isA<SqliteException>()),
      );
      storage.db.execute('PRAGMA query_only=OFF');
      await repo.prepareForUpdate(
        flush: () => repo.save(note.copyWith(body: 'retry me')),
      );
      await repo.close();
    },
  );
  test('prepare drains accepted vault retirement recovery before its queue admission', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-deletion-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final storage = GatedIntentStorage(dir.path);
    final repo = Notebook(
      storage: storage,
      keys: Keys(),
      crypto: NativeCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Synthetic');
    final id = repo.vaults.single.id;
    await storage.beginVaultDeletion(
      id,
      jsonEncode({'owner': null, 'acknowledged': true}),
    );
    storage.entered = Completer<void>();
    storage.release = Completer<void>();
    final recovering = repo.retryVaultDeletions();
    await storage.entered!.future;
    var ready = false;
    final preparing = repo.prepareForUpdate().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    storage.release!.complete();
    await recovering;
    await preparing;
    expect(storage.isVaultDeleted(id), isTrue);
    await repo.close();
  });
  test('real credential files and SQLite reopen after migration drains into update handoff', () async {
    final dir = Directory(
      Directory.systemTemp
          .createTempSync('silique-update-real-credentials-')
          .resolveSymbolicLinksSync(),
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final system = SystemKeys();
    final files = NativeCredentialFiles(Directory('${dir.path}/credentials'));
    ManagedKeys make() => ManagedKeys(files: files, system: system);
    final keys = make();
    await keys.initialize(firstRunMode: CredentialMode.system);
    final root = '${dir.path}/notebook';
    final repo = await openStartupNotebook(root, keys: keys);
    await repo.createVault('Synthetic');
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.save(note.copyWith(body: 'ordinary disk sentinel'));
    await repo.setHiddenPassword('synthetic hidden password');
    final hidden = await repo.createHiddenNote(note.vaultId);
    await repo.save(hidden.copyWith(body: 'hidden disk sentinel'));
    final expected = Map<String, String>.of(system.values);
    system.entered = Completer<void>();
    system.release = Completer<void>();
    final migration = (repo.keys as CredentialModeControl).changeMode(
      CredentialMode.local,
    );
    await system.entered!.future;
    var ready = false;
    final preparing = repo.prepareForUpdate().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    system.release!.complete();
    await migration;
    await preparing;
    expect(system.values, isEmpty);
    expect(jsonDecode((await files.read(ManagedKeys.localFile))!), expected);
    await repo.close();
    final freshKeys = make();
    await freshKeys.initialize(requireExistingKey: true);
    expect(freshKeys.mode, CredentialMode.local);
    final reopened = await openStartupNotebook(root, keys: freshKeys);
    expect(await freshKeys.read('nova.localKey'), expected['nova.localKey']);
    expect(
      reopened.notes[note.vaultId]![note.id]!.body,
      'ordinary disk sentinel',
    );
    expect(await reopened.unlockHidden('synthetic hidden password'), isTrue);
    expect(
      (await reopened.hiddenNotes(note.vaultId)).single.body,
      'hidden disk sentinel',
    );
    expect(jsonDecode((await files.read(ManagedKeys.localFile))!), expected);
    await reopened.close();
  });
  for (final action in ['purge', 'hide', 'delete-hidden']) {
    test('prepare drains accepted $action across its preflight sync', () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-update-$action-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final keys = Keys();
      final repo = GatedSyncNotebook(
        storage: NativeStorage(dir.path),
        keys: keys,
      );
      await repo.initialize();
      await repo.createVault('Synthetic');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      Note? hidden;
      if (action != 'purge') {
        await repo.setHiddenPassword('synthetic hidden password');
      } else {
        await repo.save(note.copyWith(deleted: true));
      }
      repo.session = Session(
        server: 'https://synthetic.invalid',
        token: 'fixture',
        userId: 'fixture',
        email: 'fixture@example.invalid',
      );
      repo.accountKey = repo.crypto.randomKey();
      vault.owner = repo.session!.owner;
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      if (action == 'delete-hidden') {
        hidden = await repo.createHiddenNote(vault.id);
      }
      // The real sync has acknowledged these revisions before returning.
      repo.storage.acknowledge(
        vault.id,
        repo.storage.pending(vault.id).map((r) => r.id).toList(),
      );
      repo.api = SiliqueApi(
        'https://synthetic.invalid',
        client: MockClient((_) async => http.Response('{"purged":true}', 200)),
      );
      final Future<void> mutating = switch (action) {
        'purge' => repo.purgeNote(note.copyWith(deleted: true)),
        'hide' => repo.hideNote(note),
        _ => repo.deleteHiddenNote(vault.id, hidden!.id),
      };
      await repo.entered.future;
      var ready = false;
      final preparing = repo.prepareForUpdate().then((_) => ready = true);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      repo.release.complete();
      await mutating;
      await preparing;
      expect(repo.hiddenUnlocked, isFalse);
      await repo.close();
    });
  }
  test(
    'retry of failed metadata write clears only its own unresolved failure',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-update-metadata-retry-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = await openStartupNotebook(dir.path, keys: Keys());
      await repo.createVault('Synthetic');
      final vault = repo.vaults.single;
      final storage = repo.storage as NativeStorage;
      storage.db.execute('PRAGMA query_only=ON');
      await expectLater(
        repo.renameVault(vault, 'Renamed'),
        throwsA(isA<SqliteException>()),
      );
      storage.db.execute('PRAGMA query_only=OFF');
      await expectLater(repo.prepareForUpdate(), throwsStateError);
      await repo.renameVault(vault, 'Renamed');
      await repo.prepareForUpdate();
      await repo.close();
    },
  );
  test('prepare drains a sync accepted during its async preflight', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-sync-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = await openStartupNotebook(dir.path, keys: Keys());
    repo.session = Session(
      server: 'https://synthetic.invalid',
      token: 'fixture',
      userId: 'fixture',
      email: 'fixture@example.invalid',
    );
    final entered = Completer<void>(), release = Completer<void>();
    repo.api = SiliqueApi(
      'https://synthetic.invalid',
      client: MockClient((request) async {
        entered.complete();
        await release.future;
        return http.Response(
          jsonEncode({'vaults': [], 'deletedVaults': []}),
          200,
        );
      }),
    );
    final syncing = repo.sync();
    var ready = false;
    final preparing = repo.prepareForUpdate().then((_) => ready = true);
    await entered.future;
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    release.complete();
    await syncing;
    await preparing;
    await repo.close();
  });
  test(
    'accepted journal creation drains crypto and its later serialized save',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-update-journal-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final keys = Keys();
      final crypto = GatedCrypto();
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: crypto,
      );
      await repo.initialize();
      await repo.createVault('Synthetic');
      crypto.entered = Completer<void>();
      crypto.release = Completer<void>();
      final creating = repo.createNote(
        repo.vaults.single.id,
        journalDate: '2026-10-27',
      );
      await crypto.entered!.future;
      var ready = false;
      final preparing = repo.prepareForUpdate().then((_) => ready = true);
      await Future<void>.delayed(Duration.zero);
      expect(ready, isFalse);
      crypto.release!.complete();
      final note = await creating;
      await preparing;
      await repo.close();
      final reopened = await openStartupNotebook(dir.path, keys: keys);
      expect(reopened.notes[note.vaultId]![note.id]!.journalDate, '2026-10-27');
      await reopened.close();
    },
  );
  test('prepare drains credential migration and settings and fences every unqueued mutation', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-keys-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = GatedKeys();
    final repo = await openStartupNotebook(dir.path, keys: keys);
    await repo.createVault('Synthetic');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    final control = repo.keys as CredentialModeControl;
    keys.entered = Completer<void>();
    keys.release = Completer<void>();
    final migration = control.changeMode(CredentialMode.system);
    await keys.entered!.future;
    var ready = false;
    final preparing = repo.prepareForUpdate().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(
      ready,
      isFalse,
      reason: 'credential migration must drain through activation/cleanup',
    );
    keys.release!.complete();
    await migration;
    keys.entered = null;
    keys.release = null;
    await preparing;
    final before = Map<String, String>.of(keys.values);
    final mutations = <String, Future<void> Function()>{
      'settings': () => repo.setHiddenAutoLock(null),
      'background': () => repo.setHiddenLockOnBackground(false),
      'credential write': () => repo.keys.write('nova.deviceName', 'late'),
      'credential delete': () => repo.keys.delete('nova.localKey'),
      'credential mode': () => control.changeMode(CredentialMode.local),
      'credential cleanup': control.retryCleanup,
      'unlock': () => repo.unlock(vault),
      'saveWithin': () => repo.saveWithin(note.copyWith(body: 'late')),
      'initialize': repo.initialize,
      'connect': () async {
        await repo.connect('https://invalid.invalid', 'fixture', 'fixture');
      },
      'pairing': () async {
        await repo.finishPairing({});
      },
      'recover': () => repo.recoverAccount('fixture'),
      'renameDevice': () async {
        await repo.renameDevice('fixture', 'fixture');
      },
      'disconnect': repo.disconnect,
      'startPairing': repo.startPairing,
      'offerPairing': () async {
        await repo.offerPairing({});
      },
      'approvePairing': () => repo.approvePairing({}),
    };
    for (final entry in mutations.entries) {
      await expectLater(
        Future.sync(entry.value),
        throwsStateError,
        reason: entry.key,
      );
    }
    expect(keys.values, before);
    repo.resumeAfterUpdate();
    keys.entered = Completer<void>();
    keys.release = Completer<void>();
    final setting = repo.setHiddenAutoLock(null);
    await keys.entered!.future;
    ready = false;
    final secondPrepare = repo.prepareForUpdate().then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    keys.release!.complete();
    await setting;
    await secondPrepare;
    keys.entered = null;
    keys.release = null;
    await repo.close();
    final reopened = await openStartupNotebook(dir.path, keys: keys);
    expect(reopened.hiddenAutoLock, isNull);
    expect(keys.values['nova.localKey'], before['nova.localKey']);
    await reopened.close();
  });
  test('prepare revokes queued hidden unlock only after draining its accepted edit and closes fenced', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-hidden-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = Keys();
    final repo = await openStartupNotebook(dir.path, keys: keys);
    await repo.createVault('Synthetic');
    final vaultId = repo.vaults.single.id;
    await repo.setHiddenPassword('synthetic hidden password');
    final hidden = await repo.createHiddenNote(vaultId);
    final savedKeys = Map<String, String>.of(keys.values);
    final entered = Completer<void>(), release = Completer<void>();
    final previous = repo.serialized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final accepted = repo.save(hidden.copyWith(body: 'hidden accepted edit'));
    final unlocking = repo.unlockHidden('synthetic hidden password');
    final preparing = repo.prepareForUpdate();
    release.complete();
    await previous;
    await accepted;
    await unlocking;
    await preparing;
    expect(
      repo.hiddenUnlocked,
      isFalse,
      reason: 'an earlier unlock may complete after UI lock',
    );
    expect(keys.values, savedKeys);
    await expectLater(
      repo.unlockHidden('synthetic hidden password'),
      throwsStateError,
    );
    await repo.close();
    final reopened = await openStartupNotebook(dir.path, keys: keys);
    expect(keys.values, savedKeys);
    expect(await reopened.unlockHidden('synthetic hidden password'), isTrue);
    expect(
      (await reopened.hiddenNotes(vaultId)).single.body,
      'hidden accepted edit',
    );
    await reopened.close();
  });
  test(
    'prepare drains renderer image downloads and fences new cache writes',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-update-images-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final keys = Keys();
      final repo = await openStartupNotebook(dir.path, keys: keys);
      await repo.createVault('Synthetic');
      final note = await repo.createNote(repo.vaults.single.id);
      final uri = await repo.addImage(
        note.vaultId,
        note.id,
        Uint8List.fromList([1, 2, 3]),
        'image/png',
      );
      final id = uri.split(':').last;
      final storage = repo.storage as NativeStorage;
      final manifest = storage.imageAsset(note.vaultId, id)!['manifest'];
      final payload = storage.imageChunk(note.vaultId, id, 0);
      storage.db.execute('DELETE FROM image_chunks');
      storage.db.execute('DELETE FROM image_assets');
      repo.session = Session(
        server: 'https://synthetic.invalid',
        token: 'fixture',
        userId: 'fixture',
        email: 'fixture@example.invalid',
      );
      final vault = repo.vaults.single
        ..owner = repo.session!.owner
        ..syncEnabled = true;
      storage.putVault(vault);
      final entered = Completer<void>(), release = Completer<void>();
      repo.api = SiliqueApi(
        'https://synthetic.invalid',
        client: MockClient((request) async {
          if (!request.url.path.contains('/chunks/')) {
            entered.complete();
            await release.future;
            return http.Response(
              jsonEncode({
                'manifest': manifest,
                'noteId': note.id,
                'chunkCount': 1,
              }),
              200,
            );
          }
          return http.Response(jsonEncode({'payload': payload}), 200);
        }),
      );
      final bytes = repo.imageBytes(note.vaultId, id);
      await entered.future;
      var prepared = false;
      final preparing = repo.prepareForUpdate().then((_) => prepared = true);
      await Future<void>.delayed(Duration.zero);
      expect(
        prepared,
        isFalse,
        reason: 'download accepted before the fence is still writing SQLite',
      );
      await expectLater(repo.imageBytes(note.vaultId, id), throwsStateError);
      release.complete();
      expect(await bytes, [1, 2, 3]);
      await preparing;
      repo.resumeAfterUpdate();
      await repo.close();
      final reopened = await openStartupNotebook(dir.path, keys: keys);
      expect(await reopened.imageBytes(note.vaultId, id), [1, 2, 3]);
      await reopened.close();
    },
  );
  test('busy real SQLite reader rejects checkpoint and retry preserves committed WAL', () async {
    final dir = Directory.systemTemp.createTempSync(
      'silique-update-checkpoint-',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = Keys();
    // Deliberately allow the disposable second reader on Windows too; normal
    // Windows notebooks use exclusive access and cannot model a busy reader.
    final repo = Notebook(
      storage: NativeStorage(dir.path, exclusiveAccess: false),
      keys: keys,
      crypto: NativeCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Synthetic');
    final note = await repo.createNote(repo.vaults.single.id);
    final storage = repo.storage as NativeStorage;
    final reader = sqlite3.open('${dir.path}/silique.sqlite');
    reader.execute('BEGIN');
    reader.select('SELECT * FROM documents');
    await repo.save(note.copyWith(body: 'committed in WAL'));
    await expectLater(repo.prepareForUpdate(), throwsStateError);
    expect(repo.notes[note.vaultId]![note.id]!.body, 'committed in WAL');
    reader.execute('ROLLBACK');
    reader.close();
    await repo.prepareForUpdate();
    expect(
      storage.db.select('PRAGMA wal_checkpoint(TRUNCATE)').first.values.first,
      0,
    );
    repo.resumeAfterUpdate();
    await repo.close();
    final reopened = await openStartupNotebook(dir.path, keys: keys);
    expect(reopened.notes[note.vaultId]![note.id]!.body, 'committed in WAL');
    await reopened.close();
  });
  test('failed edit is not hidden by a later successful queue item and can be retried', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-retry-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = Keys();
    final repo = await openStartupNotebook(dir.path, keys: keys);
    await repo.createVault('Synthetic');
    final note = await repo.createNote(repo.vaults.single.id);
    final storage = repo.storage as NativeStorage;
    storage.db.execute('PRAGMA query_only=ON');
    await expectLater(
      repo.save(note.copyWith(body: 'pending edit')),
      throwsA(isA<SqliteException>()),
    );
    storage.db.execute('PRAGMA query_only=OFF');
    await repo.rememberVault(note.vaultId);
    await expectLater(repo.prepareForUpdate(), throwsStateError);
    repo.resumeAfterUpdate();
    // Aborting alone must not acknowledge the failed edit.
    await expectLater(repo.prepareForUpdate(), throwsStateError);
    await repo.save(note.copyWith(body: 'pending edit'));
    await repo.prepareForUpdate();
    repo.resumeAfterUpdate();
    await repo.close();
    final reopened = await openStartupNotebook(dir.path, keys: keys);
    expect(reopened.notes[note.vaultId]![note.id]!.body, 'pending edit');
    await reopened.close();
  });
  test(
    'prepare rejects an accepted SQLite edit that fails while draining',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-update-failed-edit-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final keys = Keys();
      final repo = await openStartupNotebook(dir.path, keys: keys);
      await repo.createVault('Synthetic');
      final note = await repo.createNote(repo.vaults.single.id);
      final entered = Completer<void>(), release = Completer<void>();
      final previous = repo.serialized(() async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final storage = repo.storage as NativeStorage;
      storage.db.execute('PRAGMA query_only=ON');
      final edit = repo.save(note.copyWith(body: 'must not be lost'));
      final failedEdit = expectLater(edit, throwsA(isA<SqliteException>()));
      final preparing = repo.prepareForUpdate();
      final rejected = expectLater(preparing, throwsStateError);
      release.complete();
      await previous;
      await failedEdit;
      await rejected;
      storage.db.execute('PRAGMA query_only=OFF');
      await repo.save(note.copyWith(body: 'retry after failed handoff'));
      await repo.close();
      final reopened = await openStartupNotebook(dir.path, keys: keys);
      expect(
        reopened.notes[note.vaultId]![note.id]!.body,
        'retry after failed handoff',
      );
      await reopened.close();
    },
  );
  test('update barrier drains acknowledged SQLite saves and fences later writes until abort', () async {
    final dir = Directory.systemTemp.createTempSync('silique-update-barrier-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = Keys();
    final repo = await openStartupNotebook(dir.path, keys: keys);
    await repo.createVault('Preserve me');
    final note = await repo.createNote(repo.vaults.single.id);
    final entered = Completer<void>(), release = Completer<void>();
    final previous = repo.serialized(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final saved = repo.save(note.copyWith(body: 'acknowledged before update'));
    final dynamic dynamicRepo = repo;
    final preparing = dynamicRepo.prepareForUpdate() as Future<void>;
    var ready = false;
    unawaited(
      preparing.then((_) {
        ready = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    await expectLater(
      repo.save(note.copyWith(body: 'must not overwrite')),
      throwsStateError,
    );
    release.complete();
    await previous;
    await saved;
    await preparing;
    expect(
      repo.notes[note.vaultId]![note.id]!.body,
      'acknowledged before update',
    );
    dynamicRepo.resumeAfterUpdate();
    await repo.save(note.copyWith(body: 'usable after UAC cancellation'));
    await repo.close();
    final reopened = await openStartupNotebook(dir.path, keys: keys);
    expect(
      reopened.notes[note.vaultId]![note.id]!.body,
      'usable after UAC cancellation',
    );
    await reopened.close();
  });
}
