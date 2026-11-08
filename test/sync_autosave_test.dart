import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  test(
    'unchanged autosaves do not create encrypted revisions or wake sync',
    () async {
      final dir = Directory.systemTemp.createTempSync('sync-noop-');
      final keys = MemoryKeys();
      var notebook = Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      await notebook.initialize();
      await notebook.createVault('local');
      final vault = notebook.vaults.single;
      final note = await notebook.createNote(vault.id);
      final before = notebook.storage.revisions(vault.id).length;
      for (var i = 0; i < 100; i++) {
        await notebook.save(note.copyWith());
      }
      expect(notebook.storage.revisions(vault.id).length, before);
      await notebook.save(note.copyWith(body: 'durable edit'));
      await notebook.close();
      notebook = Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      await notebook.initialize();
      expect(notebook.notes[vault.id]![note.id]!.body, 'durable edit');
      expect(notebook.storage.pending(vault.id), isNotEmpty);
      await notebook.close();
      dir.deleteSync(recursive: true);
    },
  );
}
