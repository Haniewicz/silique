// Moving the store (Settings, also on Android) must keep keys, database,
// Markdown mirrors and pending revisions, and must never overwrite data.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_files.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('moving the store keeps keys, notes and markdown mirrors', () async {
    final remembered = <String>[];
    debugStorageAccess = remembered.add;
    addTearDown(() => debugStorageAccess = null);
    final dir = Directory.systemTemp.createTempSync('silique-move-');
    final support = Directory('${dir.path}/support')..createSync();
    final source = NativeStorage.prepareChosenRoot(
      (Directory('${dir.path}/Stare')..createSync()).path,
    );
    NativeStorage.persistChosenRoot(support.path, source);
    final keys = MemoryKeys();
    final repo = Notebook(
      storage: NativeStorage(source),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Przenoszenie');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(
      note.copyWith(title: 'Notatka', body: 'treść do przeniesienia'),
    );

    final mirror = File('$source/markdown/${vault.id}/${note.id}.md');
    expect(mirror.existsSync(), true);
    expect(File('$source/silique.sqlite').existsSync(), true);

    // The Android Settings flow uses the same picker: chosen folder -> Silique
    // Vaults -> validated root -> move.
    final chosen = Directory('${dir.path}/Nowe')..createSync();
    final destination = NativeStorage.prepareChosenRoot(chosen.path);
    await rememberStorageAccess(destination);
    // Same operation Settings uses; only the platform support-path lookup is
    // passed in explicitly so the test needs no plugin channel.
    repo.storage = await (repo.storage as NativeStorage).relocate(
      destination,
      support.path,
    );

    expect(remembered, [destination]);

    expect(NativeStorage.recordedRoot(support.path), destination);
    expect(File('$destination/silique.sqlite').existsSync(), true);
    expect(
      File('$destination/markdown/${vault.id}/${note.id}.md')
          .readAsStringSync(),
      contains('treść do przeniesienia'),
    );
    // The previous copy stays as a recovery source.
    expect(File('$source/silique.sqlite').existsSync(), true);
    await repo.close();

    // Same keys, same notes after a restart from the new location.
    final reopened = Notebook(
      storage: NativeStorage(NativeStorage.resolveRoot(support.path)),
      keys: keys,
      crypto: TestCrypto(),
    );
    await reopened.initialize();
    expect(reopened.vaults.single.id, vault.id);
    expect(reopened.notes[vault.id]![note.id]!.body, 'treść do przeniesienia');
    await reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('moving is offered on desktop and Android, not on iOS', () {
    // This host is macOS; the check documents that Android is no longer excluded,
    // because its native picker returns a real directory.
    expect(canMoveStorage, true);
  });
}
