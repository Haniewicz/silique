import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:silique/core/contracts.dart';
import 'package:silique/core/models.dart';
import 'package:silique/storage/native_storage.dart';

const target = '11111111-1111-4111-8111-111111111111';
const other = '22222222-2222-4222-8222-222222222222';

Vault vault(String id) => Vault(
  id: id,
  name: 'Synthetic $id',
  mode: 'account',
  keyWrap: 'synthetic-wrap',
  localWrap: 'synthetic-local',
  metadata: 'synthetic-metadata',
);

void main() {
  late Directory directory;
  late NativeStorage storage;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('silique-vault-delete-');
    storage = NativeStorage(directory.path);
    storage.putVault(vault(target));
    storage.putVault(vault(other));
  });
  tearDown(() async {
    await storage.close();
    directory.deleteSync(recursive: true);
  });

  test(
    'erase removes all exact namespaces and keeps unrelated data on reopen',
    () async {
      await populate(storage, target);
      await populate(storage, other);
      final unrelated = snapshot(storage, other);
      storage.db.execute('INSERT INTO documents VALUES(?,?,?)', [
        'hidden:$target-suffix',
        'note',
        'unrelated-prefix-neighbor',
      ]);
      final preserved = <File>[
        File('${directory.path}/.env'),
        File('${directory.path}/keys'),
        File('${directory.path}/config'),
        File('${directory.path}/silique-location.txt'),
      ];
      for (final file in preserved) {
        file.writeAsStringSync('synthetic-global', flush: true);
      }
      await storage.beginVaultDeletion(target, 'remote-owner/version');
      final NoteStorage api = storage;
      await api.eraseVault(target);
      expect(api.isVaultDeleted(target), isTrue);
      expect(await api.deletionIntents(), isEmpty);
      expect(
        snapshot(storage, target).values.every((rows) => rows.isEmpty),
        isTrue,
      );
      expect(snapshot(storage, other), unrelated);
      expect(storage.documents('hidden:$target-suffix'), {
        'note': 'unrelated-prefix-neighbor',
      });
      expect(
        Directory('${directory.path}/markdown/$target').existsSync(),
        isFalse,
      );
      expect(
        File('${directory.path}/markdown/$other/note.md').existsSync(),
        isTrue,
      );
      for (final file in preserved) {
        expect(file.readAsStringSync(), 'synthetic-global');
      }
      final wal = File('${directory.path}/silique.sqlite-wal');
      expect(!wal.existsSync() || wal.lengthSync() == 0, isTrue);
      await storage.close();
      storage = NativeStorage(directory.path);
      expect(storage.isVaultDeleted(target), isTrue);
      expect(
        snapshot(storage, target).values.every((rows) => rows.isEmpty),
        isTrue,
      );
      for (final writer in writers(storage, target)) {
        await expectLater(Future.sync(writer), throwsStateError);
      }
      await expectLater(storage.cancelVaultDeletion(target), throwsStateError);
      await expectLater(
        storage.beginVaultDeletion(target, 'stale'),
        throwsStateError,
      );
      await storage.eraseVault(target); // Idempotent ack/recovery.
      expect(snapshot(storage, other), unrelated);
    },
  );

  test(
    'busy WAL cleanup stays durable and automatically retries on reopen',
    () async {
      await populate(storage, target);
      await storage.beginVaultDeletion(target, 'remote-acknowledged');
      storage.db.execute('PRAGMA busy_timeout=20');
      final reader = sqlite3.open('${directory.path}/silique.sqlite');
      try {
        reader.execute('BEGIN');
        reader.select('SELECT * FROM documents');
        await expectLater(storage.eraseVault(target), throwsStateError);
        expect(storage.isVaultDeleted(target), isTrue);
        expect(
          snapshot(storage, target).values.every((rows) => rows.isEmpty),
          isTrue,
        );
        expect(
          storage.db.select('SELECT * FROM vault_deletion_cleanup'),
          hasLength(1),
        );
        expect(await storage.deletionIntents(), {
          target: 'remote-acknowledged',
        });
        expect(() => storage.putVault(vault(target)), throwsStateError);
      } finally {
        reader.close();
      }
      // Disposable interrupted/late mirror artifact, never admitted by public writers.
      final stale = Directory('${directory.path}/markdown/$target')
        ..createSync();
      File('${stale.path}/interrupted.tmp')
          .writeAsStringSync('synthetic-stale');
      await storage.close();
      storage = NativeStorage(directory.path);
      expect(
        storage.db.select('SELECT * FROM vault_deletion_cleanup'),
        isEmpty,
      );
      expect(await storage.deletionIntents(), isEmpty);
      expect(stale.existsSync(), isFalse);
      expect(storage.isVaultDeleted(target), isTrue);
      final wal = File('${directory.path}/silique.sqlite-wal');
      expect(!wal.existsSync() || wal.lengthSync() == 0, isTrue);
    },
  );

  test(
    'final checkpoint failure retains intent as well as cleanup marker',
    () async {
      await populate(storage, target);
      await storage.beginVaultDeletion(target, 'remote-acknowledged');
      storage.db.execute('PRAGMA busy_timeout=20');
      final reader = sqlite3.open('${directory.path}/silique.sqlite');
      storage.db.createFunction(
        functionName: 'synthetic_pin_reader',
        directOnly: false,
        function: (_) {
          reader.execute('BEGIN');
          reader.select('SELECT * FROM deleted_vaults');
          return 0;
        },
      );
      storage.db.execute('''CREATE TEMP TRIGGER synthetic_final_checkpoint
      BEFORE DELETE ON vault_deletion_cleanup
      BEGIN SELECT synthetic_pin_reader(); END''');
      try {
        await expectLater(storage.eraseVault(target), throwsStateError);
        expect(storage.isVaultDeleted(target), isTrue);
        expect(await storage.deletionIntents(), {
          target: 'remote-acknowledged',
        });
        expect(
          storage.db.select('SELECT * FROM vault_deletion_cleanup'),
          hasLength(1),
        );
      } finally {
        reader.close();
        storage.db.execute('DROP TRIGGER synthetic_final_checkpoint');
      }
      await storage.eraseVault(target);
      expect(await storage.deletionIntents(), isEmpty);
      expect(
        storage.db.select('SELECT * FROM vault_deletion_cleanup'),
        isEmpty,
      );
    },
  );

  test(
    'SQL deletion failure rolls back retirement and retains intent and mirrors',
    () async {
      await populate(storage, target);
      final before = snapshot(storage, target);
      await storage.beginVaultDeletion(target, 'remote-acknowledged');
      storage.db.execute(
        '''CREATE TRIGGER synthetic_delete_failure BEFORE DELETE ON documents
      BEGIN SELECT RAISE(ABORT, 'synthetic deletion failure'); END''',
      );
      await expectLater(
        storage.eraseVault(target),
        throwsA(isA<SqliteException>()),
      );
      expect(storage.isVaultDeleted(target), isFalse);
      expect(snapshot(storage, target), before);
      expect(await storage.deletionIntents(), {target: 'remote-acknowledged'});
      expect(
        File('${directory.path}/markdown/$target/note.md').existsSync(),
        isTrue,
      );
      storage.db.execute('DROP TRIGGER synthetic_delete_failure');
      await storage.eraseVault(target);
      expect(storage.isVaultDeleted(target), isTrue);
    },
  );

  test(
    'symlinked markdown parent fails closed and cleanup recovers after repair',
    () async {
      await populate(storage, target);
      final parked = Directory('${directory.path}/markdown')
          .renameSync('${directory.path}/parked');
      final link = Link('${directory.path}/markdown')..createSync(parked.path);
      await storage.beginVaultDeletion(target, 'remote-acknowledged');
      await expectLater(
        storage.eraseVault(target),
        throwsA(isA<FileSystemException>()),
      );
      expect(storage.isVaultDeleted(target), isTrue);
      expect(
        storage.db.select('SELECT * FROM vault_deletion_cleanup'),
        hasLength(1),
      );
      expect(File('${parked.path}/$target/note.md').existsSync(), isTrue);
      await storage.close();
      expect(
        () => NativeStorage(directory.path),
        throwsA(isA<FileSystemException>()),
      );
      link.deleteSync();
      parked.renameSync('${directory.path}/markdown');
      storage = NativeStorage(directory.path);
      expect(
        Directory('${directory.path}/markdown/$target').existsSync(),
        isFalse,
      );
      expect(await storage.deletionIntents(), isEmpty);
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges'
        : false,
  );

  test(
    'mirror cleanup unlinks child and nested links without following targets',
    () async {
      final external = Directory('${directory.path}/synthetic-export')
        ..createSync();
      final exported = File('${external.path}/keep.md')
        ..writeAsStringSync('unmanaged-export');
      final markdown = Directory('${directory.path}/markdown')..createSync();
      final link = Link('${markdown.path}/$target')..createSync(external.path);
      await storage.eraseVault(target);
      expect(link.existsSync(), isFalse);
      expect(exported.readAsStringSync(), 'unmanaged-export');
      final nested = Directory('${markdown.path}/$other')..createSync();
      Link('${nested.path}/export-link').createSync(external.path);
      Link('${nested.path}/broken-link')
          .createSync('${directory.path}/missing');
      await storage.eraseVault(other);
      expect(nested.existsSync(), isFalse);
      expect(exported.readAsStringSync(), 'unmanaged-export');
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires Windows privileges'
        : false,
  );

  test('mirror cleanup removes a regular-file UUID child', () async {
    Directory('${directory.path}/markdown').createSync();
    final interrupted = File('${directory.path}/markdown/$target')
      ..writeAsStringSync('synthetic-interrupted-mirror');
    await storage.eraseVault(target);
    expect(interrupted.existsSync(), isFalse);
  });

  test(
    'invalid deletion identities cause no SQL or filesystem mutation',
    () async {
      final before = snapshot(storage, target);
      for (final id in [
        '../$target',
        '$target/../$other',
        'hidden:$target',
        '',
        'not-a-uuid',
      ]) {
        await expectLater(
          storage.beginVaultDeletion(id, 'payload'),
          throwsFormatException,
        );
        await expectLater(
          storage.cancelVaultDeletion(id),
          throwsFormatException,
        );
        await expectLater(storage.eraseVault(id), throwsFormatException);
      }
      expect(snapshot(storage, target), before);
      expect(await storage.deletionIntents(), isEmpty);
      expect(storage.db.select('SELECT * FROM deleted_vaults'), isEmpty);
    },
  );

  test(
    'completed tombstone still repairs crash-window mirrors on restart',
    () async {
      await storage.eraseVault(target);
      expect(
        storage.db.select('SELECT * FROM vault_deletion_cleanup'),
        isEmpty,
      );
      final interrupted = Directory('${directory.path}/markdown/$target')
        ..createSync(recursive: true);
      File('${interrupted.path}/stale.tmp')
          .writeAsStringSync('synthetic-crash-window');
      await storage.close();
      storage = NativeStorage(directory.path);
      expect(interrupted.existsSync(), isFalse);
      expect(storage.isVaultDeleted(target), isTrue);
    },
  );

  test('remote tombstone for unknown UUID reserves identity without affecting live vaults', () async {
    const unknown = '33333333-3333-4333-8333-333333333333';
    final before = snapshot(storage, target);
    await storage.eraseVault(unknown);
    expect(storage.isVaultDeleted(unknown), isTrue);
    expect(() => storage.putVault(vault(unknown)), throwsStateError);
    expect(snapshot(storage, target), before);
  });

  test(
    'other open connection rejects stale writers after durable retirement',
    () async {
      final stale = NativeStorage(directory.path);
      try {
        await storage.beginVaultDeletion(target, 'pending');
        for (final writer in writers(stale, target)) {
          await expectLater(Future.sync(writer), throwsStateError);
        }
        await storage.eraseVault(target);
        for (final writer in writers(stale, target)) {
          await expectLater(Future.sync(writer), throwsStateError);
        }
        stale.putDocument(other, 'note', 'unaffected');
        expect(storage.documents(other), {'note': 'unaffected'});
      } finally {
        await stale.close();
      }
    },
  );

  test(
    'secure SQL cleanup and WAL checkpoint remove synthetic plaintext bytes',
    () async {
      const sentinel = 'SYNTHETIC-DELETE-PLAINTEXT-SENTINEL';
      final record = vault(target)..metadata = sentinel;
      storage.putVault(record);
      storage.putDocument(target, 'note', List.filled(2000, sentinel).join());
      storage.db.select('PRAGMA wal_checkpoint(TRUNCATE)');
      expect(
        String.fromCharCodes(
          File('${directory.path}/silique.sqlite').readAsBytesSync(),
        ),
        contains(sentinel),
      );
      await storage.eraseVault(target);
      expect(
        String.fromCharCodes(
          File('${directory.path}/silique.sqlite').readAsBytesSync(),
        ),
        isNot(contains(sentinel)),
      );
      final wal = File('${directory.path}/silique.sqlite-wal');
      expect(!wal.existsSync() || wal.lengthSync() == 0, isTrue);
      expect(
        storage.db.select('PRAGMA integrity_check').single.values.single,
        'ok',
      );
      expect(storage.db.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test(
    'SQLite fences close check-write races and reject older writer SQL',
    () async {
      await storage.beginVaultDeletion(target, 'pending');
      expect(
        () => storage.db.execute('INSERT OR REPLACE INTO vaults VALUES(?,?)', [
          target,
          '{}',
        ]),
        throwsA(isA<SqliteException>()),
      );
      await storage.eraseVault(target);
      for (final ns in namespaces(target)) {
        expect(
          () => storage.db.execute('INSERT INTO documents VALUES(?,?,?)', [
            ns,
            'stale-note',
            'stale-content',
          ]),
          throwsA(isA<SqliteException>()),
        );
        expect(
          () => storage.db.execute('INSERT INTO cursors VALUES(?,?)', [ns, 99]),
          throwsA(isA<SqliteException>()),
        );
      }
      expect(
        () => storage.db.execute('INSERT OR REPLACE INTO vaults VALUES(?,?)', [
          target,
          '{}',
        ]),
        throwsA(isA<SqliteException>()),
      );
      storage.putDocument(other, 'note', 'unaffected');
      expect(storage.documents(other), {'note': 'unaffected'});
    },
  );

  test('pending intent rejects every scoped writer until cancelled', () async {
    storage.putDocument(target, 'note', 'before');
    final acceptedMirror = storage.mirror(note(target));
    await acceptedMirror; // Domain drains accepted work BEFORE begin intent.
    await storage.beginVaultDeletion(target, 'remote-pending');
    for (final writer in writers(storage, target)) {
      await expectLater(Future.sync(writer), throwsStateError);
    }
    expect(storage.documents(target), {'note': 'before'});
    storage.putDocument(other, 'note', 'unaffected');
    expect(storage.documents(other), {'note': 'unaffected'});
    await storage.cancelVaultDeletion(target);
    storage.putDocument(target, 'note', 'resumed');
    expect(storage.documents(target)['note'], 'resumed');
  });

  test('unknown ordinary and hidden namespace writers fail closed', () async {
    const unknown = '33333333-3333-4333-8333-333333333333';
    for (final writer in writers(storage, unknown).skip(1)) {
      await expectLater(Future.sync(writer), throwsStateError);
    }
  });

  test(
    'pending intent survives reopen without deleting local content',
    () async {
      storage.putDocument(target, 'note', 'synthetic-content');
      final NoteStorage api = storage;
      await api.beginVaultDeletion(target, '{"expectedVersion":7}');
      expect(await api.deletionIntents(), {target: '{"expectedVersion":7}'});
      expect(api.isVaultDeleted(target), isFalse);
      await storage.close();
      storage = NativeStorage(directory.path);
      final NoteStorage reopened = storage;
      expect(await reopened.deletionIntents(), {
        target: '{"expectedVersion":7}',
      });
      for (final writer in writers(storage, target)) {
        await expectLater(Future.sync(writer), throwsStateError);
      }
      expect(storage.documents(target), {'note': 'synthetic-content'});
      expect(storage.vaults().map((v) => v.id), contains(target));
      await reopened.beginVaultDeletion(target, '{"expectedVersion":8}');
      expect(await reopened.deletionIntents(), {
        target: '{"expectedVersion":8}',
      });
      await reopened.cancelVaultDeletion(target);
      expect(await reopened.deletionIntents(), isEmpty);
      storage.putDocument(target, 'note', 'resumed');
      expect(storage.documents(target)['note'], 'resumed');
    },
  );
}

Note note(String id) => Note(
  id: 'note',
  vaultId: id,
  title: 'Synthetic',
  body: 'body',
  updatedAt: DateTime.utc(2026),
);

List<Future<void> Function()> writers(NativeStorage storage, String id) => [
  () async => storage.putVault(vault(id)),
  for (final prefix in [
    '',
    'hidden:',
    'hidden-sync:',
    'hidden-config:',
    'hidden-retired:',
  ])
    () async => storage.putDocument('$prefix$id', 'note', 'stale'),
  () async => storage.removeDocument('hidden:$id', 'note'),
  () async => storage.putRevision(
    Revision(
      id: 'revision',
      vaultId: id,
      noteId: 'note',
      parents: [],
      payload: 'stale',
    ),
    pending: true,
  ),
  () async => storage.putBatch(id, {'id': 'batch'}),
  () async => storage.acknowledge(id, ['revision']),
  () async => storage.setCursor(id, 55),
  () => storage.mirror(note(id)),
  () => storage.eraseNote(id, 'note', hiddenDocument: 'stale'),
  () async =>
      storage.putImageAsset(id, 'note', 'asset', 'manifest', uploaded: false),
  () async => storage.putImageChunk(id, 'asset', 0, 'stale'),
  () async => storage.markImageUploaded(id, 'asset'),
];

List<String> namespaces(String id) => [
  id,
  'hidden:$id',
  'hidden-sync:$id',
  'hidden-config:$id',
  'hidden-retired:$id',
];

Future<void> populate(NativeStorage storage, String id) async {
  for (final ns in namespaces(id)) {
    storage.putDocument(ns, 'note', 'synthetic-$id-$ns');
    storage.putRevision(
      Revision(
        id: 'revision-$ns',
        vaultId: ns,
        noteId: 'note',
        parents: [],
        payload: 'payload-$ns',
      ),
      pending: true,
    );
    storage.putBatch(ns, {'synthetic': ns});
    storage.setCursor(ns, 17);
    storage.putImageAsset(
      ns,
      'missing-note',
      'orphan',
      'manifest-$ns',
      uploaded: false,
    );
    storage.putImageChunk(ns, 'orphan', 0, 'partial-$ns');
    storage.putImageAsset(ns, 'note', 'asset', 'manifest', uploaded: true);
    storage.putImageChunk(ns, 'asset', 0, 'uploaded-$ns');
  }
  await storage.mirror(note(id));
  File('${storage.root}/markdown/$id/interrupted.md.tmp')
      .writeAsStringSync('partial-mirror');
  final nested = Directory('${storage.root}/markdown/$id/nested')..createSync();
  File('${nested.path}/orphan').writeAsStringSync('orphan-mirror');
}

Map<String, List<Map<String, Object?>>> snapshot(
  NativeStorage storage,
  String id,
) => {
  'vaults': storage.db
      .select('SELECT * FROM vaults WHERE id=?', [id])
      .map((r) => Map<String, Object?>.from(r))
      .toList(),
  for (final table in [
    'documents',
    'revisions',
    'batches',
    'cursors',
    'image_assets',
    'image_chunks',
  ])
    table: storage.db
        .select(
          'SELECT * FROM $table WHERE vault_id IN (?,?,?,?,?)',
          namespaces(id),
        )
        .map((r) => Map<String, Object?>.from(r))
        .toList(),
};
