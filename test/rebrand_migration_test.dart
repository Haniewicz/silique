import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test(
    'renamed storage retains encrypted notes, identities and queued revisions',
    () async {
      final support = Directory.systemTemp.createTempSync('silique-upgrade-');
      addTearDown(() => support.deleteSync(recursive: true));
      final oldRoot = '${support.path}/Nova Notes';
      final keys = MemoryKeys(), crypto = TestCrypto();
      var repo = Notebook(
        storage: NativeStorage(oldRoot),
        keys: keys,
        crypto: crypto,
      );
      await repo.initialize();
      await repo.createVault('Private', password: 'unchanged vault password');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(
        note.copyWith(
          title: 'Existing note',
          body: 'Existing encrypted content',
        ),
      );
      final device = repo.deviceId, keySnapshot = Map.of(keys.values);
      await repo.close();
      // This is exactly the original on-disk directory and filename, with v1 data.
      File('$oldRoot/silique.sqlite').renameSync('$oldRoot/nova.sqlite');
      final root = NativeStorage.resolveRoot(support.path);
      repo = Notebook(storage: NativeStorage(root), keys: keys, crypto: crypto);
      await repo.initialize();
      expect(repo.deviceId, device);
      expect(keys.values, keySnapshot);
      expect(repo.unlocked, isEmpty);
      await repo.unlock(
        repo.vaults.single,
        password: 'unchanged vault password',
      );
      expect(
        repo.notes[vault.id]![note.id]!.body,
        'Existing encrypted content',
      );
      expect(repo.storage.pending(vault.id), isNotEmpty);
      expect(File('$root/silique.sqlite').existsSync(), isTrue);
      expect(Directory(oldRoot).existsSync(), isFalse);
      await repo.close();
    },
  );

  test('ambiguous old and new storage is preserved without choosing or overwriting', () {
    final support = Directory.systemTemp.createTempSync('silique-ambiguous-');
    addTearDown(() => support.deleteSync(recursive: true));
    Directory('${support.path}/Nova Notes').createSync();
    Directory('${support.path}/Silique').createSync();
    expect(() => NativeStorage.resolveRoot(support.path), throwsStateError);
    expect(Directory('${support.path}/Nova Notes').existsSync(), isTrue);
    expect(Directory('${support.path}/Silique').existsSync(), isTrue);
  });
}
