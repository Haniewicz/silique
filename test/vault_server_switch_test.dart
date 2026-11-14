import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

const _server = 'https://example.invalid';

Future<Notebook> _repo(Directory dir) async {
  final repo = Notebook(
    storage: NativeStorage(dir.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );
  await repo.initialize();
  repo.session = Session(
    server: _server,
    token: 'test',
    userId: 'current-user',
    email: 'a@example.invalid',
  );
  repo.accountKey = repo.crypto.randomKey();
  return repo;
}

/// An empty response shape reused by the mock changelog endpoint.
Json _emptyChanges() => {
  'purged': <Object>[],
  'revisions': <Object>[],
  'cursor': 0,
  'hasMore': false,
};

void main() {
  test(
    'historical `server|userId` owner re-binds automatically and stores a bare user id',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-1-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      await repo.createNote(vault.id);
      vault.owner = 'https://inny.serwer|inny-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      int? putExpectedVersion;
      String? putMode;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            final body = jsonDecode(request.body) as Json;
            putExpectedVersion = body['expectedVersion'] as int?;
            putMode = (jsonDecode(body['keyWrap'] as String) as Json)['mode']
                as String?;
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      expect(requests, contains('PUT /v1/vaults/${vault.id}'));
      expect(putExpectedVersion, 0);
      expect(putMode, 'account');
      // Owner is provenance in the new bare-user-id format, never server-prefixed.
      // A historical `server|userId` value is tolerated: the provenance text
      // stays until the next successful PUT rewrites it, and only the account
      // id it carries decides qualification.
      expect(vaultOwnerUserId(repo.vaults.single.owner), 'current-user');
      expect(repo.vaults.single.syncEnabled, isTrue);
      expect(repo.syncIssues, isEmpty);
      // The queued note was still uploaded after the rebind.
      expect(
        requests.where((r) => r.startsWith('POST /v1/vaults/') && r.endsWith('/batches')),
        isNotEmpty,
      );
    },
  );

  test(
    'the same user id under a different server is not rewrapped and sends no PUT',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-2-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      await repo.createNote(vault.id);
      // Same account ("current-user"), historically tagged with another server.
      vault.owner = 'https://inny.serwer|current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      final keyWrapBefore = vault.keyWrap;

      final requests = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      expect(requests, isNot(contains('PUT /v1/vaults/${vault.id}')));
      expect(repo.vaults.single.keyWrap, keyWrapBefore);
      // A historical `server|userId` value is tolerated: the provenance text
      // stays until the next successful PUT rewrites it, and only the account
      // id it carries decides qualification.
      expect(vaultOwnerUserId(repo.vaults.single.owner), 'current-user');
    },
  );

  test(
    'an unbound vault (null owner) syncs unblocked and only then adopts the owner',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-3-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      await repo.createNote(vault.id);
      vault.owner = null;
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      expect(requests, contains('PUT /v1/vaults/${vault.id}'));
      // A historical `server|userId` value is tolerated: the provenance text
      // stays until the next successful PUT rewrites it, and only the account
      // id it carries decides qualification.
      expect(vaultOwnerUserId(repo.vaults.single.owner), 'current-user');
      expect(repo.syncIssues, isEmpty);
    },
  );

  test(
    'recreating a vault on a fresh server re-uploads all revisions parent-first',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-4-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(body: 'one'));
      await repo.save(note.copyWith(body: 'two'));
      final localOrder =
          repo.storage.revisions(vault.id).map((r) => r.id).toList();

      // Simulate "already acknowledged on the old server": everything pending=0.
      repo.storage.atomic(
        () => repo.storage.acknowledge(vault.id, localOrder),
      );
      expect(repo.storage.pending(vault.id), isEmpty);

      vault.owner = 'https://inny.serwer|inny-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      final pushed = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            pushed.addAll(ids);
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      expect(requests, contains('PUT /v1/vaults/${vault.id}'));
      final putIndex =
          requests.indexOf('PUT /v1/vaults/${vault.id}');
      final batchIndex = requests.indexWhere(
        (r) => r.startsWith('POST /v1/vaults/') && r.endsWith('/batches'),
      );
      expect(putIndex, isNonNegative);
      expect(batchIndex, isNonNegative);
      expect(putIndex, lessThan(batchIndex));
      // Every revision — acknowledged or not — is re-uploaded in DAG order.
      expect(pushed, localOrder);
    },
  );

  test(
    'a matching-account tombstone erases locally and is never recreated',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-5-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final vaultId = vault.id;
      await repo.createNote(vaultId);
      vault.owner = 'https://inny.serwer|current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final puts = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'PUT') puts.add(path);
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({
                'vaults': <Object>[],
                'deletedVaults': <Object>[vaultId],
              }),
              200,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      expect(repo.storage.isVaultDeleted(vaultId), isTrue);
      expect(puts, isNot(contains('/v1/vaults/$vaultId')));
    },
  );

  test(
    'a 410 on an automatic rebind flags the tombstone and keeps local data',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-6-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final vaultId = vault.id;
      await repo.createNote(vaultId);
      vault.owner = 'https://inny.serwer|inny-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/$vaultId') {
            return http.Response(
              jsonEncode({'error': 'vault_deleted'}),
              410,
              request: request,
            );
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Map<String, dynamic>)['id'])
                .toList();
            return http.Response(
              jsonEncode({'accepted': ids, 'batchId': body['batchId']}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.sync();

      final issue = repo.syncIssues.where((i) => i.vaultId == vaultId).toList();
      expect(issue, hasLength(1));
      expect(issue.single.reason, SyncIssue.tombstoned);
      expect(repo.storage.isVaultDeleted(vaultId), isFalse);
      expect(repo.storage.documents(vaultId), isNotEmpty);
    },
  );
}