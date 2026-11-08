import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/storage/native_storage_recovery.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support/windows_page_write_lock.dart';

void main() {
  test(
    'mapped locked SHM reproduces both 778 PRAGMAs and exclusive startup bypasses it',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-win-shm-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final root = Directory('${dir.path}/copy')..createSync();
      final writer = sqlite3.open('${dir.path}/fixture.sqlite');
      try {
        writer.execute('PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0');
        writer.execute('CREATE TABLE sentinel(value TEXT NOT NULL)');
        writer.select('PRAGMA wal_checkpoint(TRUNCATE)');
        writer.execute("INSERT INTO sentinel VALUES('only committed in WAL')");
        // Only a quiescent synthetic fixture. NOT the recovery implementation.
        for (final suffix in ['', '-wal', '-shm']) {
          File('${dir.path}/fixture.sqlite$suffix')
              .copySync('${root.path}/silique.sqlite$suffix');
        }
      } finally {
        writer.close();
      }
      final blockedShm = File('${root.path}/silique.sqlite-shm');
      final before = blockedShm.readAsBytesSync();
      final lock = WindowsPageWriteLock(
        blockedShm.path,
        mapFile: true,
        length: 8,
      );
      try {
        final original = sqlite3.open('${root.path}/silique.sqlite');
        try {
          for (final mode in ['wal', 'delete']) {
            expect(
              () => original.execute('PRAGMA journal_mode=$mode'),
              throwsA(
                isA<SqliteException>().having(
                  (e) => e.extendedResultCode,
                  'actual Windows VFS failure',
                  778,
                ),
              ),
            );
          }
        } finally {
          original.close();
        }
        final fixed = NativeStorage(root.path);
        try {
          expect(
            fixed.db.select('PRAGMA locking_mode').single.values.single,
            'exclusive',
          );
          expect(
            fixed.db.select('SELECT value FROM sentinel').single.values.single,
            'only committed in WAL',
          );
          fixed.db.execute(
            "INSERT INTO sentinel VALUES('edited after bypass')",
          );
          expect(
            fixed.db.select('PRAGMA quick_check').single.values.single,
            'ok',
          );
        } finally {
          await fixed.close();
        }
        expect(blockedShm.readAsBytesSync(), before);
        final reopened = NativeStorage(root.path);
        try {
          expect(reopened.db.select('SELECT value FROM sentinel').length, 2);
        } finally {
          await reopened.close();
        }
        expect(blockedShm.readAsBytesSync(), before);
      } finally {
        lock.close();
      }
    },
    skip: Platform.isWindows
        ? null
        : 'requires actual Win32 mapped SHM and byte lock',
  );

  test(
    'real Win32 write denial fails closed on hot journal until the lock is released',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-win32-io-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final sourceRoot = Directory('${dir.path}/source')..createSync();
      final path = '${sourceRoot.path}/silique.sqlite';
      final initial = sqlite3.open(path);
      initial.execute('PRAGMA journal_mode=DELETE');
      initial.execute('CREATE TABLE sentinel(value TEXT NOT NULL)');
      initial.execute(
        "INSERT INTO sentinel VALUES('must survive native write denial')",
      );
      initial.close();
      final before = File(path).readAsBytesSync();

      final lock = WindowsPageWriteLock(path);
      try {
        // Match both original statements against the REAL Windows VFS, not a mock.
        final oldConnection = sqlite3.open(path);
        try {
          for (final mode in ['wal', 'delete']) {
            expect(
              () => oldConnection.execute('PRAGMA journal_mode=$mode'),
              throwsA(
                isA<SqliteException>().having(
                  (e) => e.extendedResultCode,
                  'real IOERR_WRITE',
                  778,
                ),
              ),
            );
          }
        } finally {
          oldConnection.close();
        }
        expect(File(path).readAsBytesSync(), before);

        // A main-file write failure can leave a hot rollback journal. A readonly
        // backup MUST refuse it, not copy only the DB and silently lose history.
        await expectLater(
          NativeStorageRecovery.recover(
            sourceRoot.path,
            '${dir.path}/refused-copy',
          ),
          throwsA(
            isA<SqliteException>().having(
              (e) => e.extendedResultCode,
              'READONLY_ROLLBACK',
              776,
            ),
          ),
        );
        expect(Directory('${dir.path}/refused-copy').existsSync(), isFalse);
        expect(File(path).readAsBytesSync(), before);
        lock.close();
        final original = NativeStorage(sourceRoot.path);
        expect(
          original.db.select('SELECT value FROM sentinel').single.values.single,
          'must survive native write denial',
        );
        await original.close();
        final root = await NativeStorageRecovery.recover(
          sourceRoot.path,
          '${dir.path}/recovered',
        );
        final recovered = NativeStorage(root);
        try {
          expect(
            recovered.db
                .select('SELECT value FROM sentinel')
                .single
                .values
                .single,
            'must survive native write denial',
          );
          recovered.db.execute(
            "INSERT INTO sentinel VALUES('new writes work')",
          );
          expect(
            recovered.db.select('PRAGMA quick_check').single.values.single,
            'ok',
          );
        } finally {
          await recovered.close();
        }
        final reopened = NativeStorage(root);
        try {
          expect(reopened.db.select('SELECT value FROM sentinel').length, 2);
        } finally {
          await reopened.close();
        }
      } finally {
        lock.close();
      }
    },
    skip: Platform.isWindows
        ? null
        : 'actual kernel32 byte-range locks require Windows',
  );
}
