// Co-location: choosing a folder that already contains vaults must list them
// instead of silently creating a new, empty vault folder beside the data.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/location_setup.dart';

/// Creates a real Silique database at [root] holding one vault named [name].
///
/// Uses the real [NativeStorage] so the file matches exactly what
/// [NativeStorage._hasDatabase] and the startup path expect, including the
/// `vaults` table schema and a non-empty `silique.sqlite`.
Future<void> _writeVault(String root, String vaultId, String name) async {
  Directory(root).createSync(recursive: true);
  final storage = NativeStorage(root);
  storage.putVault(
    Vault(
      id: vaultId,
      name: name,
      mode: 'account',
      keyWrap: '',
      localWrap: '',
      metadata: '',
    ),
  );
  await storage.close();
}

/// Creates a valid database at [root] and renames it to [dbName] (legacy).
Future<void> _writeLegacyVault(
  String root,
  String vaultId,
  String name, {
  required String dbName,
}) async {
  await _writeVault(root, vaultId, name);
  File('$root/silique.sqlite').renameSync('$root/$dbName');
}

Future<void> _mount(
  WidgetTester tester, {
  required Future<void> Function(String root) onChosen,
  bool recovering = false,
}) async {
  await tester.pumpWidget(
    LocationSetupScreen(onChosen: onChosen, recovering: recovering),
  );
  await tester.pumpAndSettle();
}

void main() {
  late Directory root;
  final chosenRoots = <String>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('silique-colocation-');
    chosenRoots.clear();
  });

  tearDown(() {
    debugDirectoryPicker = null;
    debugStorageAccess = null;
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  testWidgets(
    'a folder holding one existing vault is adopted, not replaced by a new one',
    (tester) async {
      final picked = Directory('${root.path}/Moje dane')..createSync();
      final vaultFolder = '${picked.path}/${NativeStorage.vaultsFolderName}';
      await _writeVault(vaultFolder, 'vault-1', 'Pierwszy');
      final db = File('$vaultFolder/silique.sqlite');
      debugDirectoryPicker = () async => StorageChoice(path: picked.path);
      await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
      await tester.tap(find.byKey(const Key('choose-location')));
      await tester.pumpAndSettle();

      // The existing store is adopted directly: no new empty vault folder is
      // created beside the data.
      expect(chosenRoots, hasLength(1));
      expect(chosenRoots.single, vaultFolder);
      expect(db.existsSync(), true);
      expect(
        Directory(vaultFolder)
            .listSync()
            .where((e) => e.path.endsWith('silique.sqlite'))
            .length,
        1,
        reason: 'the existing database must not gain a sibling empty vault',
      );
      // Reopening the chosen root exposes the vault that was already there.
      final reopened = NativeStorage(chosenRoots.single);
      addTearDown(reopened.close);
      expect(reopened.vaults().map((v) => v.name), contains('Pierwszy'));
    },
  );

  testWidgets('a folder holding two vaults exposes both, not only the first', (
    tester,
  ) async {
    final picked = Directory('${root.path}/Dwie')..createSync();
    final vaultFolder = '${picked.path}/${NativeStorage.vaultsFolderName}';
    await _writeVault(vaultFolder, 'vault-1', 'Jeden');
    // Append a second vault into the same database.
    final storage = NativeStorage(vaultFolder);
    storage.putVault(
      Vault(
        id: 'vault-2',
        name: 'Dwa',
        mode: 'account',
        keyWrap: '',
        localWrap: '',
        metadata: '',
      ),
    );
    await storage.close();

    debugDirectoryPicker = () async => StorageChoice(path: picked.path);
    await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, hasLength(1));
    final reopened = NativeStorage(chosenRoots.single);
    addTearDown(reopened.close);
    expect(reopened.vaults().map((v) => v.name), containsAll(['Jeden', 'Dwa']));
    expect(reopened.vaults().length, 2);
  });

  testWidgets('an empty folder still creates a fresh vault (regression)', (
    tester,
  ) async {
    final picked = Directory('${root.path}/Pusty')..createSync();
    debugDirectoryPicker = () async => StorageChoice(path: picked.path);
    await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, hasLength(1));
    expect(chosenRoots.single, '${picked.path}/${NativeStorage.vaultsFolderName}');
    expect(
      Directory(chosenRoots.single).existsSync(),
      true,
      reason: 'an empty folder must still produce the Silique Vaults folder',
    );
  });

  testWidgets('a legacy Nova Notes folder is still recognized and adopted', (
    tester,
  ) async {
    final picked = Directory('${root.path}/Stare')..createSync();
    final legacy = Directory('${picked.path}/Nova Notes')..createSync();
    await _writeLegacyVault(
      legacy.path,
      'vault-legacy',
      'Legacy',
      dbName: 'nova.sqlite',
    );
    debugDirectoryPicker = () async => StorageChoice(path: picked.path);
    await _mount(tester, onChosen: (value) async => chosenRoots.add(value));
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    expect(chosenRoots, hasLength(1));
    // The legacy folder itself is adopted (its nova.sqlite is reopened).
    expect(chosenRoots.single, legacy.path);
    expect(File('${legacy.path}/nova.sqlite').existsSync(), true);
    expect(
      Directory('${picked.path}/${NativeStorage.vaultsFolderName}').existsSync(),
      false,
      reason: 'a legacy vault must not be shadowed by a new empty vault',
    );
  });

  testWidgets('an unreadable database reports an error, not a silent new vault', (
    tester,
  ) async {
    final picked = Directory('${root.path}/Uszkodzone')..createSync();
    final vaultFolder = '${picked.path}/${NativeStorage.vaultsFolderName}';
    Directory(vaultFolder).createSync(recursive: true);
    // A corrupt database: exists, but is not a valid SQLite file.
    File('$vaultFolder/silique.sqlite').writeAsStringSync('to nie jest sqlite');

    debugDirectoryPicker = () async => StorageChoice(path: picked.path);
    await _mount(
      tester,
      onChosen: (value) async {
        chosenRoots.add(value);
        // Opening a corrupt database throws: the app must surface this instead
        // of silently creating a new, empty store beside the data.
        NativeStorage(value);
      },
    );
    await tester.tap(find.byKey(const Key('choose-location')));
    await tester.pumpAndSettle();

    // The corrupt database is adopted (never replaced by a fresh sibling), and
    // the failure is reported instead of hidden behind empty notebooks.
    expect(chosenRoots, hasLength(1));
    expect(chosenRoots.single, vaultFolder);
    expect(find.byKey(const Key('location-error')), findsOneWidget);
    expect(
      Directory(vaultFolder)
          .listSync()
          .where((e) => e.path.endsWith('silique.sqlite'))
          .length,
      1,
      reason: 'a corrupt DB must remain the single database, no new one beside it',
    );
  });
}
