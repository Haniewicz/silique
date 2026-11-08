import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test(
    'persisted default and intentional empty title converge across two clients and reopen',
    () async {
      final dirs = List.generate(
        2,
        (_) => Directory.systemTemp.createTempSync('title-sync-'),
      );
      final keys = [MemoryKeys(), MemoryKeys()];
      Notebook make(int index) => Notebook(
        storage: NativeStorage(dirs[index].path),
        keys: keys[index],
        crypto: TestCrypto(),
      );
      var a = make(0);
      final b = make(1);
      addTearDown(() async {
        await a.close();
        await b.close();
        for (final dir in dirs) {
          dir.deleteSync(recursive: true);
        }
      });
      await a.initialize();
      await b.initialize();
      final email =
          'title-${DateTime.now().microsecondsSinceEpoch}@example.com';
      const password = 'synthetic title sync password';
      final recovery = await a.connect(
        server!,
        email,
        password,
        register: true,
      );
      await a.createVault('Title sync');
      final vault = a.vaults.single;
      await a.enableSync(vault);
      await b.connect(server, email, password, recoveryKey: recovery);
      final note = await a.createNote(vault.id);
      final journal = await a.createNote(vault.id, journalDate: '2026-10-19');
      await a.sync();
      await b.sync();
      expect(b.notes[vault.id]![note.id]!.title, 'Bez tytułu');
      await b.save(
        b.notes[vault.id]![note.id]!.copyWith(
          title: '',
          body: 'Intentionally untitled',
        ),
      );
      await b.sync();
      await a.sync();
      expect(a.notes[vault.id]![note.id]!.title, isEmpty);
      expect(a.notes[vault.id]![journal.id]!.title, '2026-10-19');
      await a.close();
      a = make(0);
      await a.initialize();
      await a.sync();
      await b.sync();
      expect(a.notes[vault.id]![note.id]!.title, isEmpty);
      expect(b.notes[vault.id]![note.id]!.title, isEmpty);
      expect(a.notes[vault.id]![note.id]!.body, 'Intentionally untitled');
    },
    skip: server == null
        ? 'Set SILIQUE_TEST_SERVER to disposable loopback server'
        : false,
  );
}
