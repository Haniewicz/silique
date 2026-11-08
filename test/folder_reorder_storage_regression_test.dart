import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/core/workspace.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('locking while an offline reorder awaits HTTP never repopulates plaintext folder metadata', () async {
    final root = Directory.systemTemp.createTempSync(
      'silique-folder-order-lock-',
    );
    final repo = Notebook(
      storage: NativeStorage(root.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(() async {
      await repo.close();
      root.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Order', password: 'folder password 12345');
    final vault = repo.vaults.single;
    for (final path in ['Alpha', 'Beta']) {
      await repo.createFolder(vault, path);
    }
    await repo.setHiddenPassword('hidden password 12345');
    final hidden = await repo.createHiddenNote(vault.id);
    await repo.save(
      hidden.copyWith(title: 'private sentinel', folder: 'HiddenOnly'),
    );
    final hiddenDocuments = Map.of(
      repo.storage.documents('hidden:${vault.id}'),
    );
    final entered = Completer<void>(), release = Completer<void>();
    repo.session = Session(
      server: 'http://127.0.0.1:1',
      token: 'synthetic',
      userId: 'fixture',
      email: 'fixture@example.com',
    );
    vault.owner = repo.session!.owner;
    vault.syncEnabled = true;
    repo.api = SiliqueApi(
      repo.session!.server,
      client: MockClient((_) async {
        entered.complete();
        await release.future;
        return http.Response('{"error":"offline"}', 503);
      }),
    );
    final changing = repo.reorderFolder(vault, 'Beta', 'Alpha', after: false);
    await entered.future;
    repo.lock(vault.id);
    release.complete();
    await changing;
    expect(
      repo.foldersOf(vault.id),
      isEmpty,
      reason: 'HTTP failure must not restore folder names after lock',
    );
    expect(repo.folderOrderOf(vault.id), isEmpty);
    expect(repo.folderRowsOf(vault.id), isEmpty);
    expect(repo.storage.documents('hidden:${vault.id}'), hiddenDocuments);
    await repo.unlock(vault, password: 'folder password 12345');
    expect(repo.folderRowsOf(vault.id).map((e) => e.path), ['Beta', 'Alpha']);
    expect(repo.allFolders(vault.id), isNot(contains('HiddenOnly')));
  });

  test('SQLite folder order is encrypted durable metadata and never rewrites note revisions', () async {
    final root = Directory.systemTemp.createTempSync('silique-folder-order-');
    final keys = MemoryKeys();
    final crypto = TestCrypto();
    Notebook make() =>
        Notebook(storage: NativeStorage(root.path), keys: keys, crypto: crypto);
    var repo = make();
    addTearDown(() async {
      await repo.close();
      root.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Order', password: 'folder password 12345');
    var vault = repo.vaults.single;
    for (final path in ['Alpha', 'Beta', 'Gamma/One', 'Gamma/Two']) {
      await repo.createFolder(vault, path);
    }
    final note = await repo.createNote(vault.id, folder: 'Gamma/One');
    final deleted = await repo.createNote(vault.id, folder: 'TrashOnly');
    await repo.save(deleted.copyWith(deleted: true));
    final before = Map.of(repo.storage.documents(vault.id));
    final outbox = jsonEncode(
      repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
    );
    final metadata = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map<String, dynamic>;
    metadata['futureField'] = {
      'sentinel': [1, 'preserve'],
    };
    vault.metadata = await crypto.seal(
      repo.unlocked[vault.id]!,
      jsonEncode(metadata),
      'silique:2:vault-meta:${vault.id}',
    );
    repo.storage.putVault(vault);
    await repo.close();
    repo = make();
    await repo.initialize();
    vault = repo.vaults.single;
    await repo.unlock(vault, password: 'folder password 12345');
    await (repo as dynamic).reorderFolder(
      vault,
      'Gamma',
      'Alpha',
      after: false,
    );
    await (repo as dynamic).reorderFolder(
      vault,
      'Gamma/Two',
      'Gamma/One',
      after: false,
    );
    expect(
      (repo as dynamic).folderRowsOf(vault.id).map((e) => e.path).toList(),
      ['Gamma', 'Gamma/Two', 'Gamma/One', 'Alpha', 'Beta'],
    );
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
    );
    expect(repo.notes[vault.id]![note.id]!.folder, 'Gamma/One');
    final decoded = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map;
    expect(decoded['futureField'], metadata['futureField']);
    final databaseFiles = root
        .listSync()
        .whereType<File>()
        .where((file) => file.path.contains('.sqlite'))
        .toList();
    expect(databaseFiles, isNotEmpty);
    for (final file in databaseFiles) {
      final bytes = latin1.decode(file.readAsBytesSync());
      for (final sentinel in [
        'Gamma',
        'TrashOnly',
        'futureField',
        'folderOrder',
      ]) {
        expect(
          bytes,
          isNot(contains(sentinel)),
          reason: 'protected SQLite/WAL must not expose folder order metadata',
        );
      }
    }
    await repo.close();
    repo = make();
    await repo.initialize();
    vault = repo.vaults.single;
    expect(repo.unlocked, isNot(contains(vault.id)));
    expect((repo as dynamic).folderRowsOf(vault.id), isEmpty);
    final sealed = vault.metadata;
    await expectLater(
      (repo as dynamic).reorderFolder(vault, 'Gamma', 'Alpha', after: true),
      throwsStateError,
    );
    expect(vault.metadata, sealed);
    await repo.unlock(vault, password: 'folder password 12345');
    expect(
      (repo as dynamic).folderRowsOf(vault.id).map((e) => e.path).toList(),
      ['Gamma', 'Gamma/Two', 'Gamma/One', 'Alpha', 'Beta'],
    );
    await expectLater(
      (repo as dynamic).reorderFolder(vault, 'Gamma/One', 'Alpha', after: true),
      throwsArgumentError,
    );
    await expectLater(
      (repo as dynamic).reorderFolder(vault, 'TrashOnly', 'Alpha', after: true),
      throwsArgumentError,
    );
    await repo.renameFolder(vault, 'Gamma', 'Renamed');
    expect(
      (repo as dynamic).folderRowsOf(vault.id).map((e) => e.path).toList(),
      ['Renamed', 'Renamed/Two', 'Renamed/One', 'Alpha', 'Beta'],
    );
    await repo.trashFolder(vault, 'Renamed');
    expect(
      (repo as dynamic).folderRowsOf(vault.id).map((e) => e.path).toList(),
      ['Alpha', 'Beta'],
    );
    expect(buildFolderTree(['Z', 'A']).map((e) => e.path), ['A', 'Z']);
  });
}
