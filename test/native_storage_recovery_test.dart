import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:silique/storage/native_storage_recovery.dart';

String _path(String value) =>
    Platform.isWindows ? value.replaceAll(r'\', '/').toLowerCase() : value;

void main() {
  late Directory sandbox;
  late Directory source;
  late String destination;

  setUp(() {
    sandbox = Directory(
      Directory.systemTemp
          .createTempSync('silique-recovery-')
          .resolveSymbolicLinksSync(),
    );
    source = Directory('${sandbox.path}/source')..createSync();
    destination = '${sandbox.path}/recovered';
  });

  tearDown(() {
    debugRecoveryBeforeSourceRead = null;
    sandbox.deleteSync(recursive: true);
  });

  for (final linkedEntry in [
    'source',
    'database',
    'wal',
    'shm',
    'journal',
    'destination',
    'parent',
  ]) {
    test('refuses $linkedEntry symlink without following it', () async {
      final db = sqlite3.open('${source.path}/silique.sqlite')
        ..execute('CREATE TABLE preserve(id TEXT)');
      db.close();
      final outside = Directory('${sandbox.path}/outside')..createSync();
      var sourceArgument = source.path;
      var targetArgument = destination;
      late Link link;
      switch (linkedEntry) {
        case 'source':
          link = Link('${sandbox.path}/source-link');
          sourceArgument = link.path;
        case 'database':
          File('${source.path}/silique.sqlite')
              .renameSync('${outside.path}/db');
          link = Link('${source.path}/silique.sqlite');
        case 'wal':
          link = Link('${source.path}/silique.sqlite-wal');
        case 'shm':
          link = Link('${source.path}/silique.sqlite-shm');
        case 'journal':
          link = Link('${source.path}/silique.sqlite-journal');
        case 'destination':
          link = Link(destination);
        case 'parent':
          link = Link('${sandbox.path}/linked-parent');
          targetArgument = '${link.path}/recovered';
      }
      final linkTarget = linkedEntry == 'source'
          ? source.path
          : linkedEntry == 'database'
          ? '${outside.path}/db'
          : outside.path;
      try {
        link.createSync(linkTarget);
      } on FileSystemException {
        markTestSkipped('Platform does not permit creating test symlinks');
        return;
      }
      await expectLater(
        NativeStorageRecovery.recover(sourceArgument, targetArgument),
        throwsA(isA<FileSystemException>()),
      );
      expect(_path(link.targetSync()), _path(linkTarget));
      expect(outside.listSync().length, linkedEntry == 'database' ? 1 : 0);
    });
  }

  for (final entry in [
    'markdown',
    'nested-file',
    'nested-directory',
    'broken-link',
  ]) {
    test(
      'fails closed on $entry link and cleans only fresh recovery files',
      () async {
        final db = sqlite3.open('${source.path}/silique.sqlite');
        db.close();
        final outside = Directory('${sandbox.path}/evidence')..createSync();
        final sentinel = File('${outside.path}/keep.txt')
          ..writeAsStringSync('untouched');
        final markdown = Directory('${source.path}/markdown');
        if (entry != 'markdown') {
          markdown.createSync();
          File('${markdown.path}/a-before-link.md')
              .writeAsStringSync('partial');
        }
        final link = Link(
          entry == 'markdown' ? markdown.path : '${markdown.path}/linked',
        );
        final target = entry == 'nested-file'
            ? sentinel.path
            : entry == 'broken-link'
            ? '${outside.path}/missing'
            : outside.path;
        try {
          link.createSync(target);
        } on FileSystemException {
          markTestSkipped('Platform does not permit creating test symlinks');
          return;
        }
        await expectLater(
          NativeStorageRecovery.recover(source.path, destination),
          throwsA(isA<FileSystemException>()),
        );
        expect(_path(link.targetSync()), _path(target));
        expect(sentinel.readAsStringSync(), 'untouched');
        expect(
          !Directory(destination).existsSync() ||
              Directory(destination).listSync().isEmpty,
          isTrue,
        );
      },
    );
  }

  for (final kind in ['file', 'link']) {
    test(
      'failure cleanup preserves a foreign $kind introduced into the fresh stage',
      () async {
        final db = sqlite3.open('${source.path}/silique.sqlite')
          ..execute('CREATE TABLE evidence(id INTEGER)');
        db.close();
        final outside = File('${sandbox.path}/foreign-target')
          ..writeAsStringSync('untouched');
        final recovery = NativeStorageRecovery.recover(
          source.path,
          destination,
        );
        final stage = Directory(destination)
            .listSync()
            .whereType<Directory>()
            .single;
        final unexpectedPath = '${stage.path}/foreign';
        if (kind == 'file') {
          File(unexpectedPath).writeAsStringSync('keep');
        } else {
          try {
            Link(unexpectedPath).createSync(outside.path);
          } on FileSystemException {
            await recovery;
            markTestSkipped('Platform does not permit creating test symlinks');
            return;
          }
        }
        await expectLater(recovery, throwsA(isA<FileSystemException>()));
        expect(File('$destination/silique.sqlite').existsSync(), isFalse);
        expect(outside.readAsStringSync(), 'untouched');
        if (kind == 'file') {
          expect(File(unexpectedPath).readAsStringSync(), 'keep');
        } else {
          expect(_path(Link(unexpectedPath).targetSync()), _path(outside.path));
        }
        expect(
          stage.listSync(followLinks: false).map((entry) => _path(entry.path)),
          [_path(unexpectedPath)],
        );
      },
    );
  }

  test('does not overwrite a completed recovery on a second attempt', () async {
    final db = sqlite3.open('${source.path}/silique.sqlite')
      ..execute('CREATE TABLE evidence(id INTEGER)');
    db.close();
    await NativeStorageRecovery.recover(source.path, destination);
    final before = File('$destination/silique.sqlite').readAsBytesSync();
    await expectLater(
      NativeStorageRecovery.recover(source.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('$destination/silique.sqlite').readAsBytesSync(), before);
  });

  test('unreadable SQLite content fails closed and preserves an existing empty destination', () async {
    final corrupt = File('${source.path}/silique.sqlite')
      ..writeAsStringSync('not a SQLite database');
    Directory(destination).createSync();
    await expectLater(
      NativeStorageRecovery.recover(source.path, destination),
      throwsA(isA<SqliteException>()),
    );
    expect(Directory(destination).existsSync(), isTrue);
    expect(Directory(destination).listSync(), isEmpty);
    expect(corrupt.readAsStringSync(), 'not a SQLite database');
  });

  test('quick_check rejects a real constraint-invalid backup and removes partial output', () async {
    final db = sqlite3.open('${source.path}/silique.sqlite');
    db.execute('CREATE TABLE evidence(id INTEGER CHECK(id > 0))');
    db.execute('PRAGMA ignore_check_constraints=ON');
    db.execute('INSERT INTO evidence VALUES (-1)');
    db.close();
    final before = File('${source.path}/silique.sqlite').readAsBytesSync();
    await expectLater(
      NativeStorageRecovery.recover(source.path, destination),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('quick_check'),
        ),
      ),
    );
    expect(Directory(destination).existsSync(), isFalse);
    expect(File('${source.path}/silique.sqlite').readAsBytesSync(), before);
  });

  test('exclusive fallback respects an existing real SQLite reader', () async {
    final reader = sqlite3.open('${source.path}/silique.sqlite');
    addTearDown(reader.close);
    reader.execute('PRAGMA journal_mode=WAL');
    reader.execute('CREATE TABLE evidence(id INTEGER)');
    reader.execute('BEGIN');
    reader.select('SELECT * FROM evidence');
    final attempts = <bool>[];
    debugRecoveryBeforeSourceRead = (_, exclusive) {
      attempts.add(exclusive);
      if (!exclusive) {
        throw SqliteException(
          extendedResultCode: 778,
          message: 'injected SHM failure',
        );
      }
    };
    await expectLater(
      NativeStorageRecovery.recover(source.path, destination),
      throwsA(
        anyOf(
          isA<NativeStorageRecoveryFailure>().having(
            (error) => error.cause.resultCode,
            'BUSY',
            SqlError.SQLITE_BUSY,
          ),
          isA<SqliteException>().having(
            (error) => error.extendedResultCode,
            'read-only descriptor cannot lock',
            3850,
          ),
        ),
      ),
    );
    expect(attempts, [false, true]);
    expect(Directory(destination).existsSync(), isFalse);
    expect(reader.select('SELECT * FROM evidence'), isEmpty);
  });

  test(
    'an unreadable exclusive fallback is attempted once and then fails closed',
    () async {
      final db = sqlite3.open('${source.path}/silique.sqlite')
        ..execute('CREATE TABLE evidence(id INTEGER)');
      db.close();
      final attempts = <bool>[];
      debugRecoveryBeforeSourceRead = (_, exclusive) {
        attempts.add(exclusive);
        throw SqliteException(
          extendedResultCode: 778,
          message: 'injected persistent I/O failure',
        );
      };
      await expectLater(
        NativeStorageRecovery.recover(source.path, destination),
        throwsA(isA<SqliteException>()),
      );
      expect(attempts, [false, true]);
      expect(Directory(destination).existsSync(), isFalse);
      // Renaming the original exercises handle release on Windows too.
      File('${source.path}/silique.sqlite')
          .renameSync('${source.path}/preserved.sqlite');
    },
  );

  test('fresh exclusive retry preserves obstructed SHM or fails closed on POSIX', () async {
    final databasePath = '${source.path}/silique.sqlite';
    final writer = sqlite3.open(databasePath);
    writer.execute('PRAGMA journal_mode=WAL');
    writer.execute('PRAGMA wal_autocheckpoint=0');
    writer.execute('CREATE TABLE evidence(id TEXT)');
    writer.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    writer.execute(
      "INSERT INTO evidence VALUES ('uncheckpointed-with-obstructed-shm')",
    );
    // Build a disposable crash-state fixture from a quiescent synthetic writer.
    // Production recovery never copies these files; it must read through SQLite.
    final base = File(databasePath).readAsBytesSync();
    final wal = File('$databasePath-wal').readAsBytesSync();
    writer.close();
    File(databasePath).writeAsBytesSync(base);
    File('$databasePath-wal').writeAsBytesSync(wal);
    final obstruction = Directory('$databasePath-shm')..createSync();
    final foreign = File('${obstruction.path}/keep.txt')
      ..writeAsStringSync('evidence');
    if (Platform.isLinux) {
      final normalDestination = '${sandbox.path}/normal-readonly';
      await NativeStorageRecovery.recover(source.path, normalDestination);
      final readable = sqlite3.open('$normalDestination/silique.sqlite');
      try {
        expect(
          readable.select('SELECT id FROM evidence').single['id'],
          'uncheckpointed-with-obstructed-shm',
        );
      } finally {
        readable.close();
      }
    }
    final attempts = <bool>[];
    debugRecoveryBeforeSourceRead = (database, exclusive) {
      attempts.add(exclusive);
      if (!exclusive) {
        // Linux can already fall back to a private index for this obstruction.
        // Inject the Windows IOERR_WRITE decision here; the exclusive attempt
        // and WAL-aware backup below still run against real native SQLite.
        throw SqliteException(
          extendedResultCode: 778,
          message: 'injected SHM I/O failure',
        );
      }
      expect(
        database.select('PRAGMA locking_mode').single.values.single,
        'exclusive',
      );
    };
    if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
      // POSIX cannot acquire an exclusive fcntl write lock on SQLite's O_RDONLY
      // source descriptor. Do not pretend that EXCLUSIVE read-only recovery is
      // portable: it must fail closed here with the real SQLite IOERR_LOCK.
      await expectLater(
        NativeStorageRecovery.recover(source.path, destination),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.extendedResultCode,
            'extendedResultCode',
            3850,
          ),
        ),
      );
      expect(Directory(destination).existsSync(), isFalse);
    } else {
      await NativeStorageRecovery.recover(source.path, destination);
      final recovered = sqlite3.open('$destination/silique.sqlite');
      try {
        expect(
          recovered.select('SELECT id FROM evidence').single['id'],
          'uncheckpointed-with-obstructed-shm',
        );
      } finally {
        recovered.close();
      }
    }
    expect(attempts, [false, true]);
    expect(File(databasePath).readAsBytesSync(), base);
    expect(File('$databasePath-wal').readAsBytesSync(), wal);
    expect(foreign.readAsStringSync(), 'evidence');
  });

  test(
    'recovers after a failed writable open leaves read-only WAL sidecars',
    () async {
      if (Platform.isWindows) {
        markTestSkipped(
          'POSIX permission fixture; native Windows lock coverage is separate',
        );
        return;
      }
      final databasePath = '${source.path}/silique.sqlite';
      final writer = sqlite3.open(databasePath);
      writer.execute('PRAGMA journal_mode=WAL');
      writer.execute('CREATE TABLE evidence(id TEXT)');
      writer.execute("INSERT INTO evidence VALUES ('persisted-mode')");
      writer.close();
      try {
        expect((await Process.run('chmod', ['444', databasePath])).exitCode, 0);
        final failedWriter = sqlite3.open(databasePath);
        try {
          expect(
            () => failedWriter.execute(
              "INSERT INTO evidence VALUES ('forbidden')",
            ),
            throwsA(isA<SqliteException>()),
          );
        } finally {
          failedWriter.close();
        }
        final paths = [
          '',
          '-wal',
          '-shm',
        ].map((suffix) => '$databasePath$suffix').toList();
        for (final path in paths) {
          expect(
            File(path).existsSync(),
            isTrue,
            reason: 'Real failed-open fixture must leave $path',
          );
          expect(
            FileStat.statSync(path).mode & 0x92,
            0,
            reason: 'Original files must have no write bits',
          );
        }
        final before = {
          for (final path in paths.take(2)) path: File(path).readAsBytesSync(),
        };
        await NativeStorageRecovery.recover(source.path, destination);
        final recovered = sqlite3.open('$destination/silique.sqlite');
        try {
          expect(
            recovered.select('SELECT id FROM evidence').single['id'],
            'persisted-mode',
          );
        } finally {
          recovered.close();
        }
        for (final path in paths) {
          expect(File(path).existsSync(), isTrue);
          expect(FileStat.statSync(path).mode & 0x92, 0);
        }
        for (final entry in before.entries) {
          expect(File(entry.key).readAsBytesSync(), entry.value);
        }
      } finally {
        for (final suffix in ['', '-wal', '-shm']) {
          final path = '$databasePath$suffix';
          if (File(path).existsSync()) {
            await Process.run('chmod', ['644', path]);
          }
        }
      }
    },
  );

  test('reads a WAL-only sentinel with base WAL SHM and source directory read-only', () async {
    if (Platform.isWindows) {
      markTestSkipped(
        'POSIX permission fixture; native Windows lock coverage is separate',
      );
      return;
    }
    final writer = sqlite3.open('${source.path}/silique.sqlite');
    try {
      writer.execute('PRAGMA journal_mode=WAL');
      writer.execute('PRAGMA wal_autocheckpoint=0');
      writer.execute(
        'CREATE TABLE evidence(id TEXT PRIMARY KEY, ciphertext BLOB)',
      );
      writer.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      writer.execute(
        "INSERT INTO evidence VALUES ('only-in-wal', x'80ff0010')",
      );
      final paths = [
        '',
        '-wal',
        '-shm',
      ].map((suffix) => '${source.path}/silique.sqlite$suffix').toList();
      final before = {
        for (final path in paths) path: File(path).readAsBytesSync(),
      };
      for (final path in paths) {
        expect((await Process.run('chmod', ['444', path])).exitCode, 0);
      }
      expect((await Process.run('chmod', ['555', source.path])).exitCode, 0);
      final permissions = {
        for (final path in [...paths, source.path])
          path: FileStat.statSync(path).mode,
      };
      await NativeStorageRecovery.recover(source.path, destination);
      final recovered = sqlite3.open('$destination/silique.sqlite');
      try {
        expect(
          recovered
              .select('SELECT ciphertext FROM evidence')
              .single['ciphertext'],
          [128, 255, 0, 16],
        );
        recovered.execute(
          "INSERT INTO evidence VALUES ('writable-new-root', x'00')",
        );
      } finally {
        recovered.close();
      }
      // SQLite may update SHM read marks even for a read-only connection when
      // another in-process connection already has a writable shared mapping.
      // The database/WAL contents and every source permission must be unchanged.
      for (final path in paths.take(2)) {
        expect(File(path).readAsBytesSync(), before[path]);
      }
      expect(File(paths.last).existsSync(), isTrue);
      for (final entry in permissions.entries) {
        expect(FileStat.statSync(entry.key).mode, entry.value);
      }
    } finally {
      // Restore disposable fixture permissions only, never production sources.
      await Process.run('chmod', ['755', source.path]);
      for (final suffix in ['', '-wal', '-shm']) {
        final path = '${source.path}/silique.sqlite$suffix';
        if (File(path).existsSync()) await Process.run('chmod', ['644', path]);
      }
      writer.close();
    }
  });

  test(
    'refuses ambiguous current and legacy databases without choosing one',
    () async {
      for (final name in ['silique.sqlite', 'nova.sqlite']) {
        final db = sqlite3.open('${source.path}/$name')
          ..execute('CREATE TABLE preserve(id TEXT)');
        db.close();
      }
      await expectLater(
        NativeStorageRecovery.recover(source.path, destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(destination).existsSync(), isFalse);
      expect(source.listSync().length, 2);
    },
  );

  test('recovers legacy nova.sqlite without renaming the source', () async {
    final db = sqlite3.open('${source.path}/nova.sqlite');
    db.execute('CREATE TABLE legacy(id TEXT)');
    db.execute("INSERT INTO legacy VALUES ('same-identity')");
    db.close();
    final before = File('${source.path}/nova.sqlite').readAsBytesSync();
    await NativeStorageRecovery.recover(source.path, destination);
    final recovered = sqlite3.open('$destination/silique.sqlite');
    try {
      expect(
        recovered.select('SELECT id FROM legacy').single['id'],
        'same-identity',
      );
    } finally {
      recovered.close();
    }
    expect(File('${source.path}/nova.sqlite').readAsBytesSync(), before);
    expect(File('${source.path}/silique.sqlite').existsSync(), isFalse);
  });

  test(
    'holds the private destination lock before the backup stream can retry',
    () async {
      final db = sqlite3.open('${source.path}/silique.sqlite');
      db.close();
      final recovery = NativeStorageRecovery.recover(source.path, destination);
      final stage = Directory(destination)
          .listSync()
          .whereType<Directory>()
          .single;
      final contender = sqlite3.open('${stage.path}/backup.sqlite');
      try {
        expect(
          () => contender.execute('BEGIN EXCLUSIVE'),
          throwsA(isA<SqliteException>()),
        );
      } finally {
        contender.close();
        await recovery;
      }
    },
  );

  test(
    'busy source fails promptly with a reason and no partial recovery',
    () async {
      final writer = sqlite3.open('${source.path}/silique.sqlite');
      addTearDown(writer.close);
      writer.execute('CREATE TABLE preserve(id INTEGER)');
      writer.execute('BEGIN EXCLUSIVE');
      final attempts = <bool>[];
      debugRecoveryBeforeSourceRead = (_, exclusive) => attempts.add(exclusive);
      final timer = Stopwatch()..start();
      await expectLater(
        NativeStorageRecovery.recover(source.path, destination),
        throwsA(
          predicate<Object>(
            (error) =>
                error.toString().contains('Source SQLite database is busy'),
          ),
        ),
      );
      expect(timer.elapsed, lessThan(const Duration(seconds: 2)));
      expect(attempts, [false]);
      expect(Directory(destination).existsSync(), isFalse);
      writer.execute('ROLLBACK');
    },
  );

  test(
    'copies the complete Markdown subtree without adopting foreign root files',
    () async {
      final db = sqlite3.open('${source.path}/silique.sqlite');
      db.close();
      final nested = Directory('${source.path}/markdown/vault/nested')
        ..createSync(recursive: true);
      File('${nested.path}/note.md').writeAsBytesSync([0, 255, 10, 13, 65]);
      Directory('${source.path}/markdown/empty').createSync();
      File('${source.path}/pointer.txt').writeAsStringSync('original-root');
      Directory(destination).createSync();
      await NativeStorageRecovery.recover(source.path, destination);
      expect(
        File('$destination/markdown/vault/nested/note.md').readAsBytesSync(),
        [0, 255, 10, 13, 65],
      );
      expect(Directory('$destination/markdown/empty').existsSync(), isTrue);
      expect(File('$destination/pointer.txt').existsSync(), isFalse);
      expect(
        File('${source.path}/pointer.txt').readAsStringSync(),
        'original-root',
      );
    },
  );

  for (final relationship in ['same', 'ancestor']) {
    test(
      'refuses a $relationship destination without modifying the source',
      () async {
        final db = sqlite3.open('${source.path}/silique.sqlite')
          ..execute('CREATE TABLE evidence(id INTEGER)');
        db.close();
        final before = File('${source.path}/silique.sqlite').readAsBytesSync();
        await expectLater(
          NativeStorageRecovery.recover(
            source.path,
            relationship == 'same' ? source.path : sandbox.path,
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(File('${source.path}/silique.sqlite').readAsBytesSync(), before);
        expect(source.listSync().length, 1);
      },
    );
  }

  test('overlap checks cannot be bypassed with trailing separators or dot segments', () async {
    final db = sqlite3.open('${source.path}/silique.sqlite');
    db.close();
    await expectLater(
      NativeStorageRecovery.recover(
        '${source.path}/',
        '${source.path}/./recovered',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory('${source.path}/recovered').existsSync(), isFalse);
  });

  test(
    'refuses a destination inside the source before creating files',
    () async {
      final db = sqlite3.open('${source.path}/silique.sqlite');
      db.close();
      final nested = '${source.path}/recovered';
      await expectLater(
        NativeStorageRecovery.recover(source.path, nested),
        throwsA(isA<FileSystemException>()),
      );
      expect(Directory(nested).existsSync(), isFalse);
    },
  );

  test('refuses nonempty destination without changing foreign files', () async {
    final db = sqlite3.open('${source.path}/silique.sqlite')
      ..execute('CREATE TABLE keep_me(id TEXT)');
    db.close();
    Directory(destination).createSync();
    final foreign = File('$destination/foreign.txt')..writeAsStringSync('keep');
    await expectLater(
      NativeStorageRecovery.recover(source.path, destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(foreign.readAsStringSync(), 'keep');
    expect(Directory(destination).listSync().map((e) => _path(e.path)), [
      _path(foreign.path),
    ]);
  });

  test('backs up committed WAL-only rows with every opaque table intact', () async {
    final writer = sqlite3.open('${source.path}/silique.sqlite');
    addTearDown(writer.close);
    writer.execute('PRAGMA journal_mode=WAL');
    writer.execute('PRAGMA wal_autocheckpoint=0');
    writer.execute('CREATE TABLE documents(id TEXT PRIMARY KEY, data BLOB)');
    writer.execute('CREATE TABLE deleted_vaults(id TEXT PRIMARY KEY)');
    writer.execute('CREATE TABLE outbox(id TEXT PRIMARY KEY, payload TEXT)');
    writer.execute('CREATE TABLE future_metadata(k TEXT, v TEXT)');
    writer.execute('CREATE INDEX metadata_key ON future_metadata(k)');
    writer.execute(
      'CREATE VIEW current_outbox AS SELECT id, payload FROM outbox',
    );
    writer.execute(
      "CREATE TRIGGER preserve_outbox BEFORE DELETE ON outbox BEGIN SELECT RAISE(ABORT, 'keep receipt'); END",
    );
    writer.execute('PRAGMA user_version=47');
    writer.execute('PRAGMA application_id=12345');
    writer.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    final mainBefore = File('${source.path}/silique.sqlite').readAsBytesSync();
    writer.execute("INSERT INTO documents VALUES ('wal-only', x'00ff1080')");
    writer.execute("INSERT INTO deleted_vaults VALUES ('retired-id')");
    writer.execute(
      "INSERT INTO outbox VALUES ('same-key', 'opaque-ciphertext')",
    );
    writer.execute(
      "INSERT INTO future_metadata VALUES ('key-id', 'existing-wrap')",
    );
    expect(
      File('${source.path}/silique.sqlite-wal').lengthSync(),
      greaterThan(0),
    );
    expect(File('${source.path}/silique.sqlite').readAsBytesSync(), mainBefore);
    final schema = writer
        .select(
          'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name',
        )
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    // A live, uncommitted WAL writer must not starve recovery or leak its row
    // into the pinned committed snapshot.
    writer.execute('BEGIN IMMEDIATE');
    writer.execute("INSERT INTO documents VALUES ('uncommitted', x'ff')");
    final walBefore = File('${source.path}/silique.sqlite-wal')
        .readAsBytesSync();
    final foreign = File('${source.path}/do-not-touch.txt')
      ..writeAsStringSync('evidence');

    expect(
      await NativeStorageRecovery.recover(source.path, destination),
      destination,
    );

    final recovered = sqlite3.open('$destination/silique.sqlite');
    try {
      expect(recovered.select('SELECT * FROM documents').single['data'], [
        0,
        255,
        16,
        128,
      ]);
      expect(
        recovered.select('SELECT * FROM deleted_vaults').single['id'],
        'retired-id',
      );
      expect(
        recovered.select('SELECT * FROM outbox').single['payload'],
        'opaque-ciphertext',
      );
      expect(recovered.select('SELECT * FROM outbox').single['id'], 'same-key');
      expect(
        recovered
            .select(
              'SELECT type,name,tbl_name,sql FROM sqlite_schema ORDER BY type,name',
            )
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
        schema,
      );
      expect(
        recovered.select('SELECT * FROM future_metadata').single['v'],
        'existing-wrap',
      );
      expect(recovered.select('PRAGMA user_version').single.values.single, 47);
      expect(
        recovered.select('PRAGMA application_id').single.values.single,
        12345,
      );
      expect(recovered.select('PRAGMA quick_check').single.values.single, 'ok');
    } finally {
      recovered.close();
    }
    expect(File('${source.path}/silique.sqlite').readAsBytesSync(), mainBefore);
    expect(
      File('${source.path}/silique.sqlite-wal').readAsBytesSync(),
      walBefore,
    );
    expect(File('${source.path}/silique.sqlite-shm').existsSync(), isTrue);
    expect(foreign.readAsStringSync(), 'evidence');
  });
}
