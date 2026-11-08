import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_window.dart';
import 'package:sqlite3/sqlite3.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' as home;

void main() {
  testWidgets(
    'normal close does not wait for a reader to release committed WAL pages',
    (tester) async {
      late Directory dir;
      late Notebook repo;
      final keys = MemoryKeys();
      final crypto = TestCrypto();
      await tester.runAsync(() async {
        dir = Directory.systemTemp.createTempSync('silique-close-wal-');
        // Shared-lock mode deliberately permits a real external reader. Windows
        // production defaults to exclusive mode, so this proves this causal path,
        // not that this reader exists on the owner's Windows installation.
        repo = Notebook(
          storage: NativeStorage(dir.path, exclusiveAccess: false),
          keys: keys,
          crypto: crypto,
        );
        await repo.initialize();
        await repo.createVault('Close checkpoint');
        final note = await repo.createNote(repo.vaults.single.id);
        await repo.save(
          note.copyWith(title: 'Before close', body: 'durable body'),
        );
      });
      final storage = repo.storage as NativeStorage;
      final note = repo.notes.values.single.values.single;
      final reader = sqlite3.open('${dir.path}/silique.sqlite');
      var readerClosed = false;
      reader.execute('BEGIN');
      reader.select('SELECT * FROM documents');
      addTearDown(() async {
        if (!readerClosed) reader.close();
        await tester.pumpWidget(const SizedBox());
        await storage.close();
        dir.deleteSync(recursive: true);
      });
      await home.mount(tester, repo, desktop: true);
      await tester.enterText(
        find.byKey(const Key('note-title')),
        'Last edit at close',
      );
      expect(
        storage.db.select('PRAGMA busy_timeout').single.values.single,
        5000,
      );
      var readerWaits = 0;
      // Count actual SQLite busy-handler admission instead of sleeping. The
      // Linux Flutter tester does not establish Windows wall-clock timing;
      // native Windows is needed for an end-to-end process-exit measurement.
      storage.db.busyHandler = (_) {
        readerWaits++;
        return false;
      };
      final elapsed = Stopwatch()..start();
      var finished = false;
      final closing = NativeWindow.instance.beforeClose!().then(
        (_) => finished = true,
      );
      await home.drainUntil(tester, () => finished);
      await closing;
      elapsed.stop();
      debugPrint(
        'CLOSE_CHECKPOINT elapsed_ms=${elapsed.elapsedMilliseconds} '
        'reader_waits=$readerWaits '
        'wal_bytes=${File('${dir.path}/silique.sqlite-wal').lengthSync()}',
      );
      expect(
        readerWaits,
        0,
        reason: 'Normal close must not enter the busy wait for an external read snapshot',
      );
      expect(
        storage.documents(note.vaultId)[note.id],
        contains('Last edit at close'),
      );
      expect(
        File('${dir.path}/silique.sqlite-wal').lengthSync(),
        greaterThan(0),
        reason:
            'Keep committed WAL needed by the reader; never delete sidecars',
      );
      reader.execute('ROLLBACK');
      // A WAL connection itself retains shared locks on Windows even after its
      // transaction ends. Close this intentionally external reader before the
      // following production-default EXCLUSIVE reopen, not only in teardown.
      reader.close();
      readerClosed = true;
      await tester.pumpWidget(const SizedBox());
      await storage.close();
      await tester.runAsync(() async {
        final reopened = Notebook(
          storage: NativeStorage(dir.path),
          keys: keys,
          crypto: crypto,
        );
        await reopened.initialize();
        expect(
          reopened.notes[note.vaultId]![note.id]!.title,
          'Last edit at close',
        );
        expect(reopened.notes[note.vaultId]![note.id]!.body, 'durable body');
        await reopened.close();
      });
    },
  );
}
