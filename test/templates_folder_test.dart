import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/system_folders.dart';
import 'package:silique/core/templates.dart';
import 'package:silique/l10n/strings.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('a new vault starts with Szablony and ensure stays idempotent', () async {
    final dir = Directory.systemTemp.createTempSync('silique-templates-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(repo.close);
    await repo.initialize();
    await repo.createVault('Local');
    final vault = repo.vaults.single;

    // Seeded in the vault's first metadata write, before any UI is mounted.
    expect(repo.allFolders(vault.id), contains(templatesFolder));

    await repo.ensureTemplatesFolder(vault);
    expect(repo.allFolders(vault.id), contains(templatesFolder));
    expect(repo.foldersOf(vault.id), contains(templatesFolder));

    // A second call must not duplicate the stored entry.
    await repo.ensureTemplatesFolder(vault);
    expect(
      repo.foldersOf(vault.id).where((p) => p == templatesFolder).length,
      1,
    );
  });

  test('ensureTemplatesFolder keeps a single entry for Szablony', () async {
    final dir = Directory.systemTemp.createTempSync('silique-templates-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(repo.close);
    await repo.initialize();
    await repo.createVault('Local');
    final vault = repo.vaults.single;

    await repo.createNote(vault.id, folder: templatesFolder);
    expect(repo.allFolders(vault.id), contains(templatesFolder));

    await repo.ensureTemplatesFolder(vault);
    // Still exactly one stored entry; a note in the folder never duplicates it.
    expect(
      repo.foldersOf(vault.id).where((path) => path == templatesFolder).length,
      1,
    );
  });

  test('ensureTemplatesFolder is a no-op on a locked vault', () async {
    final dir = Directory.systemTemp.createTempSync('silique-templates-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    addTearDown(repo.close);
    await repo.initialize();
    await repo.createVault('Protected', password: 'a valid vault password');
    final vault = repo.vaults.last;
    repo.lock(vault.id);

    expect(repo.unlocked.containsKey(vault.id), isFalse);
    await repo.ensureTemplatesFolder(vault);
    expect(repo.allFolders(vault.id), isEmpty);

    // The folder is part of the sealed metadata, so it appears on unlock
    // without any extra ensure call, and a repeated ensure keeps it single.
    await repo.unlock(vault, password: 'a valid vault password');
    expect(repo.foldersOf(vault.id), contains(templatesFolder));
    await repo.ensureTemplatesFolder(vault);
    expect(
      repo.foldersOf(vault.id).where((path) => path == templatesFolder).length,
      1,
    );
  });

  test('ensureTemplatesFolder survives a restart', () async {
    final dir = Directory.systemTemp.createTempSync('silique-templates-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final keys = MemoryKeys();
    final crypto = TestCrypto();
    var repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: crypto,
    );
    await repo.initialize();
    await repo.createVault('Local');
    final vault = repo.vaults.single;
    await repo.ensureTemplatesFolder(vault);
    await repo.close();

    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: crypto,
    );
    addTearDown(repo.close);
    await repo.initialize();
    expect(repo.foldersOf(vault.id), contains(templatesFolder));
  });

  test(
    'deleting Szablony throws while deleting another folder still works',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-templates-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(repo.close);
      await repo.initialize();
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      await repo.ensureTemplatesFolder(vault);

      await expectLater(
        repo.trashFolder(vault, templatesFolder),
        throwsA(isA<StateError>()),
      );
      // Case-insensitive guard: a differently-cased spelling is still rejected.
      await expectLater(
        repo.trashFolder(vault, templatesFolder.toLowerCase()),
        throwsA(isA<StateError>()),
      );
      expect(repo.foldersOf(vault.id), contains(templatesFolder));

      // An ordinary folder remains deletable.
      await repo.createFolder(vault, 'Ordinary');
      await repo.trashFolder(vault, 'Ordinary');
      expect(repo.foldersOf(vault.id), isNot(contains('Ordinary')));
      expect(repo.foldersOf(vault.id), contains(templatesFolder));
    },
  );

  test(
    'renaming or moving Szablony throws while an ordinary folder renames',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-templates-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(repo.close);
      await repo.initialize();
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      await repo.ensureTemplatesFolder(vault);
      await repo.createFolder(vault, 'Szablony/Nested');

      // Renaming the built-in folder (exact and differently-cased) is rejected.
      await expectLater(
        repo.renameFolder(vault, templatesFolder, 'X'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.renameFolder(vault, templatesFolder.toLowerCase(), 'X'),
        throwsA(isA<StateError>()),
      );
      // Moving it into another folder is rejected too.
      await expectLater(
        repo.renameFolder(vault, templatesFolder, 'Ordinary/Szablony'),
        throwsA(isA<StateError>()),
      );
      // A subfolder under `Szablony` is protected as well.
      await expectLater(
        repo.renameFolder(vault, 'Szablony/Nested', 'X'),
        throwsA(isA<StateError>()),
      );
      expect(repo.foldersOf(vault.id), contains(templatesFolder));

      // An ordinary folder remains renamable.
      await repo.createFolder(vault, 'Ordinary');
      await repo.renameFolder(vault, 'Ordinary', 'Renamed');
      expect(repo.allFolders(vault.id), contains('Renamed'));
      expect(repo.allFolders(vault.id), isNot(contains('Ordinary')));
    },
  );

  test(
    'an English vault seeds Templates and a language switch adds nothing',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-templates-en-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(repo.close);
      await repo.initialize();
      currentLanguageCode = 'en';
      addTearDown(() => currentLanguageCode = 'pl');
      await repo.createVault('Local');
      final vault = repo.vaults.single;

      // The seed uses the current-language name at creation time.
      expect(repo.foldersOf(vault.id), contains('Templates'));

      // Switching back to Polish must not seed a duplicate `Szablony`.
      currentLanguageCode = 'pl';
      await repo.ensureTemplatesFolder(vault);
      expect(repo.foldersOf(vault.id).where((p) => p == 'Templates').length, 1);
      expect(repo.foldersOf(vault.id), isNot(contains('Szablony')));
    },
  );

  test(
    'guards recognize the English Templates alias and its subtree',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-templates-en-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(repo.close);
      await repo.initialize();
      currentLanguageCode = 'en';
      addTearDown(() => currentLanguageCode = 'pl');
      await repo.createVault('Local');
      final vault = repo.vaults.single;
      await repo.ensureTemplatesFolder(vault);
      await repo.createFolder(vault, 'Templates/Nested');

      // The root alias is protected from deletion and renaming/moving.
      await expectLater(
        repo.trashFolder(vault, 'Templates'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.renameFolder(vault, 'Templates', 'X'),
        throwsA(isA<StateError>()),
      );
      // A subfolder under the alias is protected from renaming too.
      await expectLater(
        repo.renameFolder(vault, 'Templates/Nested', 'X'),
        throwsA(isA<StateError>()),
      );
      expect(repo.foldersOf(vault.id), contains('Templates'));
    },
  );
}
