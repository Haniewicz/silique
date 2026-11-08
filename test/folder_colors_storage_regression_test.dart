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
  test('folder color merge, remap and decode follow the pure preference rules', () {
    expect(
      decodeFolderColors(<Object?, Object?>{
        'A': 0xFF000000,
        ' A': 1,
        'B': -1,
        'C': 'x',
        5: 1,
        'D/E': 0xFFFFFFFF,
      }),
      {'A': 0xFF000000, 'D/E': 0xFFFFFFFF},
      reason: 'only normalized paths with 32-bit ARGB values are read',
    );
    expect(decodeFolderColors(null), isEmpty);
    expect(
      mergeFolderColors(base: {'A': 1}, local: {'A': 1}, server: {}),
      isEmpty,
      reason: 'a removal wins over a stale copy',
    );
    expect(
      mergeFolderColors(base: {'A': 1}, local: {}, server: {'A': 1}),
      isEmpty,
      reason: 'a local removal wins over an unchanged server copy',
    );
    expect(
      mergeFolderColors(base: {}, local: {'A': 1}, server: {'B': 2}),
      {'A': 1, 'B': 2},
      reason: 'two independent color additions both survive',
    );
    expect(
      mergeFolderColors(base: {'A': 1}, local: {'A': 2}, server: {'A': 3}),
      {'A': 3},
      reason: 'concurrent same-path edits use the confirmed server color',
    );
    expect(
      remapFolderColors({'A/B': 1, 'A': 2, 'C': 3}, 'A', 'X'),
      {'X/B': 1, 'X': 2, 'C': 3},
      reason: 'colors follow the renamed subtree like folder order does',
    );
    expect(
      remapFolderColors({'A/B': 1, 'C': 3}, 'A', null),
      {'C': 3},
      reason: 'trashing a folder forgets its subtree color entries',
    );
  });

  test('locking while an offline color change awaits HTTP never repopulates plaintext folder metadata', () async {
    final root = Directory.systemTemp.createTempSync(
      'silique-folder-color-lock-',
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
    await repo.createVault('Colors', password: 'folder password 12345');
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
    final changing = repo.setFolderColor(vault, 'Alpha', 0xFF112233);
    await entered.future;
    repo.lock(vault.id);
    release.complete();
    expect(
      await changing,
      isFalse,
      reason: 'an offline color change stays local instead of failing',
    );
    expect(
      repo.foldersOf(vault.id),
      isEmpty,
      reason: 'HTTP failure must not restore folder names after lock',
    );
    expect(repo.folderColorsOf(vault.id), isEmpty);
    expect(repo.folderOrderOf(vault.id), isEmpty);
    expect(repo.folderRowsOf(vault.id), isEmpty);
    expect(repo.storage.documents('hidden:${vault.id}'), hiddenDocuments);
    await repo.unlock(vault, password: 'folder password 12345');
    expect(repo.folderColorsOf(vault.id), {'Alpha': 0xFF112233});
    expect(repo.allFolders(vault.id), isNot(contains('HiddenOnly')));
  });

  test('SQLite folder colors are encrypted durable metadata and never rewrite note revisions', () async {
    final root = Directory.systemTemp.createTempSync('silique-folder-colors-');
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
    await repo.createVault('Colors', password: 'folder password 12345');
    var vault = repo.vaults.single;
    for (final path in [
      'Alpha',
      'Beta',
      'Gamma/One',
      'Gamma/Two',
      'Projekty/Żółw',
    ]) {
      await repo.createFolder(vault, path);
    }
    final note = await repo.createNote(vault.id, folder: 'Gamma/One');
    final deleted = await repo.createNote(vault.id, folder: 'TrashOnly');
    await repo.save(deleted.copyWith(deleted: true));
    final before = Map.of(repo.storage.documents(vault.id));
    final outbox = jsonEncode(
      repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
    );

    expect(await repo.setFolderColor(vault, 'Alpha', 0xFF112233), isTrue);
    expect(await repo.setFolderColor(vault, 'Gamma/One', 0x80ABCDEF), isTrue);
    expect(await repo.setFolderColor(vault, 'Projekty/Żółw', 0x00000001), isTrue);
    expect(repo.folderColorsOf(vault.id), {
      'Alpha': 0xFF112233,
      'Gamma/One': 0x80ABCDEF,
      'Projekty/Żółw': 0x00000001,
    });
    expect(repo.notes[vault.id]![note.id]!.folder, 'Gamma/One');
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
      reason: 'color preferences never rewrite note documents or revisions',
    );

    // Rejected input never reaches storage.
    final sealedBefore = vault.metadata;
    await expectLater(
      repo.setFolderColor(vault, 'Missing', 0xFF000000),
      throwsArgumentError,
    );
    await expectLater(
      repo.setFolderColor(vault, '/Alpha', 0xFF000000),
      throwsArgumentError,
    );
    await expectLater(
      repo.setFolderColor(vault, '..', 0xFF000000),
      throwsArgumentError,
    );
    await expectLater(
      repo.setFolderColor(vault, 'TrashOnly', 0xFF000000),
      throwsArgumentError,
      reason: 'a folder that only exists in the trash is not a vault folder',
    );
    await expectLater(repo.setFolderColor(vault, 'Alpha', -1), throwsArgumentError);
    await expectLater(
      repo.setFolderColor(vault, 'Alpha', 0x100000000),
      throwsArgumentError,
    );
    expect(vault.metadata, sealedBefore);
    expect(repo.folderColorsOf(vault.id)['Alpha'], 0xFF112233);

    // Encrypted map keys decrypt identical, and an unknown metadata key is
    // preserved by later color writes (same contract as folder order).
    final metadata = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map<String, dynamic>;
    expect(metadata['folderColors'], {
      'Alpha': 0xFF112233,
      'Gamma/One': 0x80ABCDEF,
      'Projekty/Żółw': 0x00000001,
    });
    final base = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.folderBase,
        'silique:2:folder-base:${vault.id}',
      ),
    ) as Map;
    expect(
      decodeFolderColors(base['folderColors']),
      repo.folderColorsOf(vault.id),
      reason: 'a confirmed write also becomes the encrypted color merge base',
    );
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
    expect(
      repo.folderColorsOf(vault.id),
      {
        'Alpha': 0xFF112233,
        'Gamma/One': 0x80ABCDEF,
        'Projekty/Żółw': 0x00000001,
      },
      reason: 'colors survive a Notebook restart through real SQLite',
    );
    expect(repo.storage.documents(vault.id), before);
    expect(
      jsonEncode(
        repo.storage.pending(vault.id).map((r) => r.toWire()).toList(),
      ),
      outbox,
    );

    // Folder order remaps its preference on rename, so colors follow the
    // subtree as well — documented decision: consistency with the existing
    // reorder pattern. Trash forgets the subtree entries, again like order.
    await repo.renameFolder(vault, 'Gamma', 'Renamed');
    expect(repo.folderColorsOf(vault.id), {
      'Alpha': 0xFF112233,
      'Renamed/One': 0x80ABCDEF,
      'Projekty/Żółw': 0x00000001,
    });
    await repo.trashFolder(vault, 'Renamed');
    expect(repo.folderColorsOf(vault.id), {
      'Alpha': 0xFF112233,
      'Projekty/Żółw': 0x00000001,
    });
    expect(await repo.setFolderColor(vault, 'Alpha', null), isTrue);
    expect(repo.folderColorsOf(vault.id), {'Projekty/Żółw': 0x00000001});
    expect(
      await repo.setFolderColor(vault, 'Alpha', null),
      isTrue,
      reason: 'clearing an already absent entry is a no-op, not an error',
    );
    final decoded = jsonDecode(
      await crypto.open(
        repo.unlocked[vault.id]!,
        vault.metadata,
        'silique:2:vault-meta:${vault.id}',
      ),
    ) as Map;
    expect(decoded['futureField'], metadata['futureField']);
    expect(
      decodeFolderColors(decoded['folderColors']),
      repo.folderColorsOf(vault.id),
      reason: 'the stored map round-trips through the validating decoder',
    );

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
        'folderColors',
      ]) {
        expect(
          bytes,
          isNot(contains(sentinel)),
          reason: 'protected SQLite/WAL must not expose folder color metadata',
        );
      }
    }

    await repo.close();
    repo = make();
    await repo.initialize();
    vault = repo.vaults.single;
    expect(repo.unlocked, isNot(contains(vault.id)));
    expect(repo.folderColorsOf(vault.id), isEmpty);
    final sealed = vault.metadata;
    await expectLater(
      repo.setFolderColor(vault, 'Projekty/Żółw', 0xFF000000),
      throwsStateError,
    );
    await expectLater(
      repo.setFolderColor(vault, 'Projekty/Żółw', null),
      throwsStateError,
    );
    expect(vault.metadata, sealed);
    await repo.unlock(vault, password: 'folder password 12345');
    expect(repo.folderColorsOf(vault.id), {'Projekty/Żółw': 0x00000001});
  });
}
