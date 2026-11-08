import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test('permanent local deletion removes documents, history and Markdown after restart', () async {
    final dir = Directory.systemTemp.createTempSync('silique-purge-');
    final keys = MemoryKeys();
    final repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Local');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await expectLater(repo.purgeNote(note), throwsStateError);
    final deleted = note.copyWith(body: 'private', deleted: true);
    await repo.save(deleted);
    await repo.purgeNote(deleted);
    expect(repo.storage.documents(vault.id), isEmpty);
    expect(repo.storage.revisions(vault.id), isEmpty);
    await repo.close();
    final reopened = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await reopened.initialize();
    expect(reopened.notes[vault.id], isEmpty);
    await reopened.close();
    dir.deleteSync(recursive: true);
  });

  test('relocation preserves queued revisions and resolves the new location on restart', () async {
    final dir = Directory.systemTemp.createTempSync('silique-relocate-');
    final root = Directory('${dir.path}/source')..createSync();
    final support = Directory('${dir.path}/support')..createSync();
    final destination = '${dir.path}/destination';
    final keys = MemoryKeys();
    final repo = Notebook(
      storage: NativeStorage(root.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Local');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(note.copyWith(body: 'after move'));
    final count = repo.storage.pending(vault.id).length;
    repo.storage = await (repo.storage as NativeStorage).relocate(
      destination,
      support.path,
    );
    expect(NativeStorage.resolveRoot(support.path), destination);
    expect(repo.storage.pending(vault.id).length, count);
    await repo.close();
    final reopened = Notebook(
      storage: NativeStorage(NativeStorage.resolveRoot(support.path)),
      keys: keys,
      crypto: TestCrypto(),
    );
    await reopened.initialize();
    expect(reopened.notes[vault.id]![note.id]!.body, 'after move');
    expect(File('${root.path}/silique.sqlite').existsSync(), true);
    final occupied = Directory('${dir.path}/occupied')..createSync();
    File('${occupied.path}/keep').writeAsStringSync('keep');
    await expectLater(
      (reopened.storage as NativeStorage).relocate(occupied.path, support.path),
      throwsStateError,
    );
    expect(File('${occupied.path}/keep').readAsStringSync(), 'keep');
    await reopened.close();
    dir.deleteSync(recursive: true);
  });
}
