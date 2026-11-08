import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  late Directory dir;
  late Notebook repo;
  late MemoryKeys keys;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('vault-delete-domain-');
    keys = MemoryKeys();
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Target');
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });
  test(
    'lost remote ACK fences content across restart and retries idempotently',
    () async {
      final target = repo.vaults.single;
      final note = await repo.createNote(target.id);
      target.owner = 'http://127.0.0.1|owner';
      target.syncEnabled = true;
      target.version = 7;
      repo.storage.putVault(target);
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'synthetic',
        userId: 'owner',
        email: 'fixture@example.com',
      );
      var deleted = false;
      var calls = 0;
      var rejectRetry = false;
      SiliqueApi client() => SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((request) async {
          if (request.url.path == '/.well-known/silique') {
            return http.Response('{"features":{"vault_deletion":true}}', 200);
          }
          if (request.method == 'DELETE') {
            calls++;
            if (rejectRetry) return http.Response('{"error":"revoked"}', 401);
            expect(jsonDecode(request.body)['expectedVersion'], 7);
            if (!deleted) {
              deleted = true;
              throw http.ClientException('lost after commit');
            }
            return http.Response(
              jsonEncode({'deleted': true, 'vaultId': target.id}),
              200,
            );
          }
          return http.Response('{}', 500);
        }),
      );
      repo.api = client();
      await expectLater(
        repo.deleteVault(target, confirmation: 'Target'),
        throwsA(isA<http.ClientException>()),
      );
      expect(deleted, isTrue);
      expect(repo.storage.documents(target.id), contains(note.id));
      expect(await repo.storage.deletionIntents(), contains(target.id));
      await expectLater(
        repo.save(note.copyWith(body: 'late')),
        throwsStateError,
      );
      await repo.close();
      repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      await repo.initialize();
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'synthetic',
        userId: 'owner',
        email: 'fixture@example.com',
      );
      repo.api = client();
      rejectRetry = true;
      await expectLater(
        repo.retryVaultDeletions(),
        throwsA(isA<ApiException>()),
      );
      expect(
        await repo.storage.deletionIntents(),
        contains(target.id),
        reason: 'a rejection cannot disprove an earlier uncertain commit',
      );
      rejectRetry = false;
      await Future.wait([
        repo.retryVaultDeletions(),
        repo.retryVaultDeletions(),
      ]);
      expect(calls, 3);
      expect(repo.vaults, isEmpty);
      expect(repo.storage.isVaultDeleted(target.id), isTrue);
      expect(await repo.storage.deletionIntents(), isEmpty);
    },
  );
  test('a sync queued just before delete cannot start a content pass during confirmation request', () async {
    final target = repo.vaults.single;
    target.owner = 'http://127.0.0.1|owner';
    target.syncEnabled = true;
    repo.storage.putVault(target);
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'owner',
      email: 'fixture@example.com',
    );
    final entered = Completer<void>(), release = Completer<void>();
    var lists = 0;
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((r) async {
        if (r.url.path == '/.well-known/silique') {
          entered.complete();
          await release.future;
          return http.Response('{"features":{"vault_deletion":true}}', 200);
        }
        if (r.method == 'DELETE') {
          return http.Response(
            jsonEncode({'deleted': true, 'vaultId': target.id}),
            200,
          );
        }
        lists++;
        return http.Response('{"vaults":[],"deletedVaults":[]}', 200);
      }),
    );
    final sync = repo.sync();
    final deletion = repo.deleteVault(target, confirmation: 'Target');
    await entered.future;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final listsBeforeAck = lists;
    release.complete();
    await Future.wait([sync, deletion]);
    expect(listsBeforeAck, 0);
  });
  test(
    'uncertain deletion blocks reading cached attachments as well as writes',
    () async {
      final target = repo.vaults.single;
      final note = await repo.createNote(target.id);
      final ref = await repo.addImage(
        target.id,
        note.id,
        Uint8List.fromList([1, 2, 3]),
        'image/png',
      );
      target.owner = 'http://127.0.0.1|owner';
      target.syncEnabled = true;
      repo.storage.putVault(target);
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'fixture',
        userId: 'owner',
        email: 'fixture@example.com',
      );
      repo.api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient(
          (request) async => request.method == 'GET'
              ? http.Response('{"features":{"vault_deletion":true}}', 200)
              : throw http.ClientException('uncertain'),
        ),
      );
      await expectLater(
        repo.deleteVault(target, confirmation: 'Target'),
        throwsA(isA<http.ClientException>()),
      );
      await expectLater(
        repo.imageBytes(target.id, ref.split(':').last),
        throwsStateError,
      );
    },
  );
  test('remote tombstone revokes locked vault without content key before any upload', () async {
    final target = repo.vaults.single;
    final note = await repo.createNote(target.id);
    target.owner = 'http://127.0.0.1|owner';
    target.syncEnabled = false;
    repo.storage.putVault(target);
    repo.lock(target.id);
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'owner',
      email: 'fixture@example.com',
    );
    repo.accountKey = null;
    final paths = <String>[];
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((request) async {
        paths.add(request.url.path);
        return http.Response(
          jsonEncode({
            'vaults': [],
            'deletedVaults': [target.id],
          }),
          200,
        );
      }),
    );
    await repo.sync();
    expect(repo.vaults, isEmpty);
    expect(repo.storage.documents(target.id), isNot(contains(note.id)));
    expect(repo.storage.isVaultDeleted(target.id), isTrue);
    expect(paths, ['/v1/vaults']);
  });
  for (final status in [400, 401, 403, 404, 409, 429, 503]) {
    test(
      'remote rejection $status never loses local contents or lies about completion',
      () async {
        final target = repo.vaults.single;
        final note = await repo.createNote(target.id);
        target.owner = 'http://127.0.0.1|owner';
        target.syncEnabled = true;
        repo.storage.putVault(target);
        repo.session = Session(
          server: 'http://127.0.0.1',
          token: 'fixture',
          userId: 'owner',
          email: 'fixture@example.com',
        );
        repo.api = SiliqueApi(
          'http://127.0.0.1',
          client: MockClient(
            (r) async => r.method == 'GET'
                ? http.Response('{"features":{"vault_deletion":true}}', 200)
                : http.Response('{"error":"rejected"}', status),
          ),
        );
        await expectLater(
          repo.deleteVault(target, confirmation: 'Target'),
          throwsA(isA<ApiException>()),
        );
        expect(repo.storage.documents(target.id), contains(note.id));
        expect(repo.storage.isVaultDeleted(target.id), isFalse);
        expect(repo.vaultDeletionPending(target.id), status == 503);
        expect(
          (await repo.storage.deletionIntents()).containsKey(target.id),
          status == 503,
        );
      },
    );
  }
  test('wrong name locked foreign disabled and unsupported vaults are not silently deleted locally', () async {
    final target = repo.vaults.single;
    for (final name in ['', 'target', 'Target ', ' Target']) {
      await expectLater(
        repo.deleteVault(target, confirmation: name),
        throwsStateError,
      );
    }
    repo.lock(target.id);
    await expectLater(
      repo.deleteVault(target, confirmation: 'Target'),
      throwsStateError,
    );
    await repo.unlock(target);
    target.owner = 'http://127.0.0.1|owner';
    repo.storage.putVault(target);
    await expectLater(
      repo.deleteVault(target, confirmation: 'Target'),
      throwsStateError,
    );
    target.syncEnabled = true;
    repo.storage.putVault(target);
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'foreign',
      email: 'fixture@example.com',
    );
    var deletes = 0;
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((r) async {
        if (r.method == 'DELETE') deletes++;
        return http.Response('{"features":{}}', 200);
      }),
    );
    await expectLater(
      repo.deleteVault(target, confirmation: 'Target'),
      throwsStateError,
    );
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'owner',
      email: 'fixture@example.com',
    );
    await expectLater(
      repo.deleteVault(target, confirmation: 'Target'),
      throwsStateError,
    );
    expect(deletes, 0);
    expect(await repo.storage.deletionIntents(), isEmpty);
    expect(repo.vaultDeletionPending(target.id), isFalse);
    expect(repo.vaults, hasLength(1));
  });
  test('snapshot failure keeps acknowledged cleanup intent and retry finishes last vault', () async {
    final target = repo.vaults.single;
    final note = await repo.createNote(target.id);
    await repo.rememberVault(target.id);
    repo.revokeVaultSnapshot = (_) async =>
        throw StateError('native cleanup failed');
    await expectLater(
      repo.deleteVault(target, confirmation: 'Target'),
      throwsStateError,
    );
    expect(repo.storage.documents(target.id), contains(note.id));
    expect(await repo.storage.deletionIntents(), contains(target.id));
    repo.revokeVaultSnapshot = (_) async {};
    await repo.retryVaultDeletions();
    expect(repo.vaults, isEmpty);
    expect(repo.lastVaultId, isNull);
    expect(keys.values['nova.lastVault'], isNull);
  });
  test('confirmed local deletion retires all contents and keys but preserves another vault', () async {
    final target = repo.vaults.single;
    final ordinary = await repo.createNote(target.id);
    await repo.save(ordinary.copyWith(body: 'delete ordinary'));
    await repo.setHiddenPassword('synthetic hidden password');
    final hidden = await repo.createHiddenNote(target.id);
    await repo.save(hidden.copyWith(body: 'delete hidden'));
    await repo.createVault('Keep');
    final keep = repo.vaults.last;
    final keepNote = await repo.createNote(keep.id);
    await repo.rememberVault(target.id);
    final localKey = keys.values['nova.localKey'];
    final hiddenWrap = keys.values['silique.hidden.wrap'];
    final key = repo.unlocked[target.id]!;
    await repo.deleteVault(target, confirmation: 'Target');
    expect(repo.vaults.map((v) => v.id), [keep.id]);
    expect(repo.notes[target.id], isNull);
    expect(repo.unlocked[target.id], isNull);
    expect(key, everyElement(0));
    expect(repo.storage.documents('hidden:${target.id}'), isEmpty);
    expect(repo.storage.revisions(target.id), isEmpty);
    expect(repo.storage.isVaultDeleted(target.id), isTrue);
    expect(repo.notes[keep.id], contains(keepNote.id));
    expect(repo.lastVaultId, keep.id);
    expect(keys.values['nova.localKey'], localKey);
    expect(keys.values['silique.hidden.wrap'], hiddenWrap);
    await expectLater(repo.save(ordinary), throwsStateError);
    await expectLater(repo.unlock(target), throwsStateError);
  });
  test('a failing deletion retry never blocks tombstones of another vault', () async {
    final stuck = repo.vaults.single;
    stuck.owner = 'http://127.0.0.1|owner';
    stuck.syncEnabled = true;
    stuck.version = 4;
    repo.storage.putVault(stuck);
    final stuckNote = await repo.createNote(stuck.id);
    await repo.save(stuckNote.copyWith(body: 'kept while fenced'));
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'owner',
      email: 'fixture@example.com',
    );
    var list = <String, Object?>{
      'vaults': <Object?>[],
      'deletedVaults': <Object?>[],
    };
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((r) async {
        if (r.url.path == '/.well-known/silique') {
          return http.Response('{"features":{"vault_deletion":true}}', 200);
        }
        if (r.method == 'DELETE') {
          return http.Response('{"error":"try later"}', 500);
        }
        return http.Response(jsonEncode(list), 200);
      }),
    );
    await expectLater(
      repo.deleteVault(stuck, confirmation: 'Target'),
      throwsA(isA<ApiException>()),
    );
    expect(repo.vaultDeletionPending(stuck.id), isTrue);

    await repo.createVault('Gone');
    final gone = repo.vaults.last;
    gone.owner = 'http://127.0.0.1|owner';
    gone.syncEnabled = true;
    repo.storage.putVault(gone);
    final goneNote = await repo.createNote(gone.id);
    list = {
      // The account still owns the fenced vault, so nothing was deleted there.
      'vaults': [
        {'id': stuck.id},
      ],
      'deletedVaults': [gone.id],
    };
    await repo.sync();

    expect(repo.storage.isVaultDeleted(gone.id), isTrue);
    expect(repo.vaults.map((v) => v.id), [stuck.id]);
    expect(repo.storage.documents(gone.id), isNot(contains(goneNote.id)));
    expect(repo.storage.documents(stuck.id), contains(stuckNote.id));
    expect(
      repo.vaultDeletionPending(stuck.id),
      isFalse,
      reason: 'the server still owns the vault, so the fence must not stick',
    );
    expect(await repo.storage.deletionIntents(), isEmpty);
  });
  test(
    'an unresolved attempt stays fenced until the server lists the vault',
    () async {
      final target = repo.vaults.single;
      target.owner = 'http://127.0.0.1|owner';
      target.syncEnabled = true;
      repo.storage.putVault(target);
      final note = await repo.createNote(target.id);
      await repo.save(note.copyWith(body: 'must survive an unknown outcome'));
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'fixture',
        userId: 'owner',
        email: 'fixture@example.com',
      );
      var list = <String, Object?>{
        'vaults': <Object?>[],
        'deletedVaults': <Object?>[],
      };
      repo.api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((r) async {
          if (r.url.path == '/.well-known/silique') {
            return http.Response('{"features":{"vault_deletion":true}}', 200);
          }
          if (r.method == 'DELETE') {
            return http.Response('{"error":"try later"}', 500);
          }
          return http.Response(jsonEncode(list), 200);
        }),
      );
      await expectLater(
        repo.deleteVault(target, confirmation: 'Target'),
        throwsA(isA<ApiException>()),
      );
      await repo.sync();
      expect(
        repo.vaultDeletionPending(target.id),
        isTrue,
        reason: 'an absent id proves neither commit nor rejection',
      );
      expect(repo.storage.documents(target.id), contains(note.id));
      expect(await repo.storage.deletionIntents(), contains(target.id));

      list = {
        'vaults': [
          {'id': target.id},
        ],
        'deletedVaults': <Object?>[],
      };
      await repo.sync();
      expect(repo.vaultDeletionPending(target.id), isFalse);
      expect(await repo.storage.deletionIntents(), isEmpty);
      expect(repo.storage.documents(target.id), contains(note.id));
      expect(repo.vaults.single.id, target.id);
      await repo.save(note.copyWith(body: 'writable again'));
    },
  );
}
