import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'exclusive startup reads WAL-only commits without touching obstructed SHM',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-shm-bypass-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final writer = sqlite3.open('${dir.path}/fixture.sqlite');
      final target = Directory('${dir.path}/target')..createSync();
      try {
        writer.execute('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0');
        writer.execute('CREATE TABLE sentinel(value TEXT NOT NULL)');
        writer.select('PRAGMA wal_checkpoint(TRUNCATE)');
        writer.execute("INSERT INTO sentinel VALUES('committed only in WAL')");
        // Quiescent SYNTHETIC fixture, never an operational recovery mechanism.
        File('${dir.path}/fixture.sqlite')
            .copySync('${target.path}/silique.sqlite');
        File('${dir.path}/fixture.sqlite-wal')
            .copySync('${target.path}/silique.sqlite-wal');
      } finally {
        writer.close();
      }
      final shm = Directory('${target.path}/silique.sqlite-shm')..createSync();
      File('${shm.path}/keep.txt')
          .writeAsStringSync('do not remove the obstruction');
      expect(
        () => NativeStorage(target.path, exclusiveAccess: false),
        throwsA(isA<StorageOpenFailure>()),
      );
      final storage = NativeStorage(target.path, exclusiveAccess: true);
      try {
        expect(
          storage.db.select('SELECT value FROM sentinel').single.values.single,
          'committed only in WAL',
        );
        storage.db.execute(
          "INSERT INTO sentinel VALUES('writable after startup')",
        );
        expect(
          storage.db.select('PRAGMA locking_mode').single.values.single,
          'exclusive',
        );
        expect(
          File('${shm.path}/keep.txt').readAsStringSync(),
          'do not remove the obstruction',
        );
      } finally {
        await storage.close();
      }
      final reopened = NativeStorage(target.path, exclusiveAccess: true);
      expect(reopened.db.select('SELECT value FROM sentinel').length, 2);
      await reopened.close();
    },
  );

  test(
    'a failed readonly open includes native and SQLite error codes',
    () async {
      if (Platform.isWindows) {
        return; // Native Win32 write-lock fixture runs in CI.
      }
      final dir = Directory.systemTemp.createTempSync('silique-native-error-');
      final path = '${dir.path}/silique.sqlite';
      final original = sqlite3.open(path);
      original.execute('CREATE TABLE sentinel(value TEXT)');
      original.close();
      Process.runSync('chmod', ['444', path]);
      try {
        expect(
          () => NativeStorage(dir.path),
          throwsA(
            isA<StorageOpenFailure>()
                .having(
                  (e) => e.diagnostics['sqlite_primary_code'],
                  'primary',
                  8,
                )
                .having(
                  (e) => e.diagnostics['sqlite_extended_code'],
                  'extended',
                  isA<int>(),
                )
                .having(
                  (e) => e.diagnostics['native_error_source'],
                  'native error source',
                  isA<String>(),
                ),
          ),
        );
      } finally {
        Process.runSync('chmod', ['644', path]);
        dir.deleteSync(recursive: true);
      }
    },
  );

  test(
    'reopening a persisted rollback database preserves its journal mode',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-preserve-journal-',
      );
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/silique.sqlite';
      final original = sqlite3.open(path);
      original.execute('PRAGMA journal_mode=DELETE');
      original.execute('CREATE TABLE sentinel(value TEXT NOT NULL)');
      original.execute(
        "INSERT INTO sentinel VALUES('existing durable contents')",
      );
      original.close();

      final storage = NativeStorage(dir.path);
      try {
        expect(
          storage.db.select('PRAGMA journal_mode').single.values.single,
          'delete',
        );
        expect(storage.journalMode, 'delete');
        expect(
          storage.db.select('SELECT value FROM sentinel').single.values.single,
          'existing durable contents',
        );
        expect(storage.db.select('PRAGMA synchronous').single.values.single, 2);
      } finally {
        await storage.close();
      }
    },
  );
}
