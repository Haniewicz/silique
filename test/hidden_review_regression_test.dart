import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'core_test.dart' show MemoryKeys, TestCrypto;

class PausingCrypto extends TestCrypto {
  String? pausePrefix;
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();

  @override
  Future<String> seal(List<int> key, String plain, String aad) async {
    final sealed = await super.seal(key, plain, aad);
    if (pausePrefix != null && aad.startsWith(pausePrefix!)) {
      pausePrefix = null;
      entered.complete();
      await release.future;
    }
    return sealed;
  }
}

void configureSynced(
  Notebook repo,
  Future<http.Response> Function(http.Request) onDelete,
) {
  repo.session = Session(
    server: 'http://127.0.0.1',
    token: 'test',
    userId: 'test',
    email: 'test@example.com',
  );
  repo.accountKey = repo.localKey;
  final vault = repo.vaults.single
    ..owner = repo.session!.owner
    ..syncEnabled = true;
  repo.storage.putVault(vault);
  repo.api = SiliqueApi(
    'http://127.0.0.1',
    client: MockClient((request) async {
      if (request.method == 'DELETE') return onDelete(request);
      if (request.url.path == '/v1/vaults') {
        return http.Response('{"vaults":[]}', 200);
      }
      if (request.url.path.endsWith('/batches')) {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'batchId': body['batchId'],
            'accepted': (body['revisions'] as List)
                .map((r) => r['id'])
                .toList(),
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/changes')) {
        return http.Response(
          '{"revisions":[],"purged":[],"cursor":0,"hasMore":false}',
          200,
        );
      }
      throw StateError(
        'Unexpected test request: ${request.method} ${request.url}',
      );
    }),
  );
}

void main() {
  late Notebook repo;
  late Directory dir;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hidden-review-regression-');
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: PausingCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Private');
    await repo.setHiddenPassword('additional password');
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });

  for (final lock in ['hidden lock', 'expiry', 'vault lock']) {
    test('reveal rechecks $lock after asynchronous revision crypto', () async {
      final note = await repo.createHiddenNote(repo.vaults.single.id);
      final crypto = repo.crypto as PausingCrypto;
      crypto.pausePrefix = 'silique:2:note:';
      final revealing = repo.unhideNote(note.vaultId, note.id);
      final assertion = expectLater(revealing, throwsStateError);
      await crypto.entered.future;
      Future<void>? locking;
      if (lock == 'hidden lock') {
        locking = repo.lockHidden();
      } else if (lock == 'expiry') {
        await repo.setHiddenAutoLock(const Duration(milliseconds: 20));
        sleep(const Duration(milliseconds: 50));
      } else {
        repo.lock(note.vaultId);
      }
      crypto.release.complete();
      await assertion;
      await locking;
      expect(repo.storage.documents(note.vaultId), isEmpty);
      expect(repo.storage.revisions(note.vaultId), isEmpty);
      expect(repo.storage.documents('hidden:${note.vaultId}'), hasLength(1));
      expect(
        File('${dir.path}/markdown/${note.vaultId}/${note.id}.md').existsSync(),
        isFalse,
      );
    });
  }

  for (final status in [403, 429, 503]) {
    test(
      'actual DELETE $status preserves the recoverable move state',
      () async {
        final note = await repo.createNote(repo.vaults.single.id);
        var deletes = 0;
        var responseStatus = status;
        configureSynced(repo, (_) async {
          deletes++;
          return http.Response(
            responseStatus == 200 ? '{"purged":true}' : '{}',
            responseStatus,
          );
        });
        await expectLater(
          repo.hideNote(note),
          throwsA(
            isA<ApiException>().having((e) => e.status, 'status', status),
          ),
        );
        expect(
          deletes,
          1,
          reason: 'Must reach DELETE, not fail during pre-sync',
        );
        expect(repo.storage.pending(note.vaultId), isEmpty);
        expect(
          repo.storage.documents('hidden-retired:${note.vaultId}'),
          isEmpty,
        );
        if (status < 500) {
          expect(repo.storage.documents(note.vaultId).keys, [note.id]);
          expect(repo.notes[note.vaultId]!.keys, [note.id]);
          expect(repo.storage.documents('hidden:${note.vaultId}'), isEmpty);
        } else {
          expect(repo.storage.documents(note.vaultId), isEmpty);
          expect(repo.notes[note.vaultId], isEmpty);
          expect(
            repo.storage.documents('hidden:${note.vaultId}'),
            hasLength(1),
          );
          responseStatus = 200;
          await repo.sync();
          expect(deletes, 2);
          expect(
            repo.storage.documents('hidden-retired:${note.vaultId}')[note.id],
            '1',
          );
          await repo.sync();
          expect(
            deletes,
            2,
            reason: 'Confirmed retirement must not repeat DELETE',
          );
        }
      },
    );
  }

  test(
    'editing a recoverable hide still retires its old ordinary identity',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      var deletes = 0;
      var serverStillHasOrdinary = true;
      configureSynced(repo, (_) async {
        deletes++;
        if (deletes == 1) return http.Response('{}', 503);
        serverStillHasOrdinary = false;
        return http.Response('{"purged":true}', 200);
      });
      await expectLater(repo.hideNote(note), throwsA(isA<ApiException>()));
      expect(serverStillHasOrdinary, isTrue);
      final hidden = (await repo.hiddenNotes(note.vaultId)).single;
      await repo.save(hidden.copyWith(body: 'edited while offline'));
      await repo.sync();
      expect(deletes, 2, reason: 'The old ordinary note must be purged');
      expect(serverStillHasOrdinary, isFalse);
      expect(
        repo.storage.documents('hidden-retired:${note.vaultId}'),
        contains(note.id),
      );
      await repo.sync();
      expect(deletes, 2);
    },
  );

  test('large attachment restore rolls back ordinary rows chunks and hidden removal together', () async {
    final storage = repo.storage as NativeStorage;
    final note = await repo.createNote(repo.vaults.single.id);
    final bytes = Uint8List(800000)..fillRange(0, 800000, 42);
    final uri = await repo.addImage(note.vaultId, note.id, bytes, 'image/png');
    await repo.save(note.copyWith(body: '![large]($uri)'));
    await repo.hideNote(repo.notes[note.vaultId]![note.id]!);
    final encrypted = storage.documents('hidden:${note.vaultId}');
    storage.db.execute(
      "CREATE TRIGGER fail_restored_chunk BEFORE INSERT ON image_chunks WHEN NEW.chunk_index=1 BEGIN SELECT RAISE(ABORT, 'chunk write failed'); END",
    );
    await expectLater(
      repo.unhideNote(note.vaultId, note.id),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(storage.documents('hidden:${note.vaultId}'), encrypted);
    expect(storage.documents(note.vaultId), isEmpty);
    expect(storage.pending(note.vaultId), isEmpty);
    expect(repo.notes[note.vaultId], isEmpty);
    expect(storage.db.select('SELECT * FROM image_assets'), isEmpty);
    expect(storage.db.select('SELECT * FROM image_chunks'), isEmpty);
    storage.db.execute('DROP TRIGGER fail_restored_chunk');
    final restored = await repo.unhideNote(note.vaultId, note.id);
    expect(storage.documents('hidden:${note.vaultId}'), isEmpty);
    final id = RegExp(r'silique-image:([a-f0-9-]{36})')
        .firstMatch(restored.body)!
        .group(1)!;
    expect(await repo.imageBytes(note.vaultId, id), orderedEquals(bytes));
    expect(storage.revisions(note.vaultId).single.parents, isEmpty);
  });

  for (final operation in ['save', 'hide', 'create']) {
    test(
      'expired session rejects $operation even before timer callback',
      () async {
        final hidden = await repo.createHiddenNote(repo.vaults.single.id);
        final ordinary = await repo.createNote(hidden.vaultId);
        await repo.setHiddenAutoLock(const Duration(milliseconds: 20));
        sleep(const Duration(milliseconds: 50));
        expect(repo.hiddenUnlocked, isFalse);
        final action = switch (operation) {
          'save' => repo.save(hidden.copyWith(body: 'too late')),
          'hide' => repo.hideNote(ordinary),
          _ => repo.createHiddenNote(hidden.vaultId),
        };
        await expectLater(action, throwsStateError);
        expect(repo.storage.documents(hidden.vaultId).keys, [ordinary.id]);
        expect(repo.storage.documents('hidden:${hidden.vaultId}').keys, [
          hidden.id,
        ]);
      },
    );
  }

  test(
    'hide requires explicit purge acknowledgement before retiring identity',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      var deletes = 0;
      configureSynced(repo, (_) async {
        deletes++;
        return http.Response('{}', 200);
      });
      await expectLater(repo.hideNote(note), throwsFormatException);
      expect(deletes, 1);
      expect(repo.storage.documents('hidden:${note.vaultId}'), hasLength(1));
      expect(repo.storage.documents('hidden-retired:${note.vaultId}'), isEmpty);
      expect(repo.storage.documents(note.vaultId), isEmpty);
    },
  );

  for (final operation in ['sync', 'reveal']) {
    test(
      '$operation retries pending purge but rejects invalid acknowledgement',
      () async {
        final hidden = await repo.createHiddenNote(repo.vaults.single.id);
        repo.storage.removeDocument(
          'hidden-retired:${hidden.vaultId}',
          hidden.id,
        );
        var deletes = 0;
        configureSynced(repo, (_) async {
          deletes++;
          return http.Response('{"purged":false}', 200);
        });
        await expectLater(
          operation == 'sync'
              ? repo.sync()
              : repo.unhideNote(hidden.vaultId, hidden.id),
          throwsFormatException,
        );
        expect(deletes, 1);
        expect(
          repo.storage.documents('hidden:${hidden.vaultId}'),
          hasLength(1),
        );
        expect(
          repo.storage.documents('hidden-retired:${hidden.vaultId}'),
          isEmpty,
        );
        expect(repo.storage.documents(hidden.vaultId), isEmpty);
      },
    );
  }

  for (final field in ['id', 'vaultId', 'hidden']) {
    test('reveal validates encrypted hidden $field before moving it', () async {
      final hidden = await repo.createHiddenNote(repo.vaults.single.id);
      final salt = await repo.keys.read('silique.hidden.salt');
      final wrapping = await repo.crypto.passwordKey(
        'additional password',
        base64Decode(salt!),
      );
      final key = base64Decode(
        await repo.crypto.open(
          wrapping,
          (await repo.keys.read('silique.hidden.wrap'))!,
          'silique:1:hidden-key',
        ),
      );
      final invalid = hidden.toJson();
      invalid[field] = field == 'hidden' ? false : 'wrong-identity';
      final envelope = await repo.crypto.seal(
        key,
        jsonEncode(invalid),
        'silique:1:hidden:${hidden.vaultId}:${hidden.id}',
      );
      repo.storage.putDocument('hidden:${hidden.vaultId}', hidden.id, envelope);
      await expectLater(
        repo.unhideNote(hidden.vaultId, hidden.id),
        throwsFormatException,
      );
      expect(repo.storage.documents(hidden.vaultId), isEmpty);
      expect(repo.storage.documents('hidden:${hidden.vaultId}'), {
        hidden.id: envelope,
      });
      expect(repo.storage.pending(hidden.vaultId), isEmpty);
    });
  }

  test(
    'stale hidden save cannot recreate a revealed synced identity',
    () async {
      final hidden = await repo.createHiddenNote(repo.vaults.single.id);
      final vault = repo.vaults.single..owner = 'http://127.0.0.1|test';
      repo.storage.putVault(vault);
      final revealing = repo.unhideNote(hidden.vaultId, hidden.id);
      final stale = expectLater(
        repo.save(hidden.copyWith(body: 'stale')),
        throwsStateError,
      );
      final restored = await revealing;
      await stale;
      expect(restored.id, isNot(hidden.id));
      expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
      expect(repo.storage.documents(vault.id).keys, [restored.id]);
    },
  );

  test('fresh hidden envelope and local marker roll back together', () async {
    final storage = repo.storage as NativeStorage;
    final vaultId = repo.vaults.single.id;
    storage.db.execute(
      "CREATE TRIGGER fail_marker BEFORE INSERT ON documents WHEN NEW.vault_id LIKE 'hidden-retired:%' BEGIN SELECT RAISE(ABORT, 'marker write failed'); END",
    );
    await expectLater(
      repo.createHiddenNote(vaultId),
      throwsA(isA<sqlite.SqliteException>()),
    );
    expect(storage.documents('hidden:$vaultId'), isEmpty);
    expect(storage.documents('hidden-retired:$vaultId'), isEmpty);
    expect(storage.documents(vaultId), isEmpty);
    expect(storage.pending(vaultId), isEmpty);
  });

  test(
    'expired hidden session must reject reveal before overdue timer runs',
    () async {
      final note = await repo.createHiddenNote(repo.vaults.single.id);
      await repo.save(note.copyWith(body: 'expired secret'));
      await repo.setHiddenAutoLock(const Duration(milliseconds: 20));
      sleep(const Duration(milliseconds: 50));
      expect(repo.hiddenUnlocked, isFalse);
      await expectLater(
        repo.unhideNote(note.vaultId, note.id),
        throwsStateError,
      );
      expect(repo.storage.documents(note.vaultId), isEmpty);
    },
  );

  test(
    'lock request must cancel queued reveal rather than publish plaintext',
    () async {
      final note = await repo.createHiddenNote(repo.vaults.single.id);
      await repo.save(note.copyWith(body: 'queued secret'));
      final gate = Completer<void>();
      final blocked = repo.serialized(() => gate.future);
      final revealing = repo.unhideNote(note.vaultId, note.id);
      final locking = repo.lockHidden();
      expect(repo.hiddenUnlocked, isFalse);
      final assertion = expectLater(revealing, throwsStateError);
      gate.complete();
      await blocked;
      await assertion;
      await locking;
      expect(repo.storage.documents(note.vaultId), isEmpty);
    },
  );

  test(
    'reveal after actual busy WAL checkpoint really restores the ordinary row',
    () async {
      final storage = repo.storage as NativeStorage;
      final note = await repo.createNote(repo.vaults.single.id);
      await repo.save(note.copyWith(body: 'recover this'));
      storage.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      storage.db.execute('PRAGMA busy_timeout=20');
      final reader = sqlite.sqlite3.open('${dir.path}/silique.sqlite');
      reader.execute('BEGIN');
      reader.select('SELECT * FROM documents');
      try {
        await expectLater(
          repo.hideNote(repo.notes[note.vaultId]![note.id]!),
          throwsStateError,
        );
      } finally {
        reader.execute('ROLLBACK');
        reader.close();
      }
      expect(storage.documents(note.vaultId), isEmpty);
      expect(storage.documents('hidden:${note.vaultId}'), hasLength(1));
      final restored = await repo.unhideNote(note.vaultId, note.id);
      expect(storage.documents(note.vaultId).containsKey(restored.id), isTrue);
      expect(storage.documents('hidden:${note.vaultId}'), isEmpty);
    },
  );
}
