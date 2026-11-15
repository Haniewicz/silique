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

  test(
    'switching an image-bearing vault to a fresh server re-uploads the image '
    'before the batch and finishes sync',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-7-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      final reference = await repo.addImage(
        vault.id,
        note.id,
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
        'image/png',
      );
      final imageId = reference.split(':').last;
      await repo.save(note.copyWith(body: '![photo]($reference)'));

      // Simulate "already uploaded to the old server": the image asset is acked.
      repo.storage.markImageUploaded(vault.id, imageId);
      expect(repo.storage.pendingImages(vault.id), isEmpty);
      expect(repo.storage.imageAsset(vault.id, imageId)!['uploaded'], 1);

      // Acknowledged revisions: only the server switch must force re-upload.
      repo.storage.atomic(
        () => repo.storage.acknowledge(
          vault.id,
          repo.storage.revisions(vault.id).map((r) => r.id).toList(),
        ),
      );
      expect(repo.storage.pending(vault.id), isEmpty);

      vault.owner = 'https://inny.serwer|inny-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      final uploadedChunks = <String>[];
      final uploadedManifests = <String>[];
      final acceptedBatches = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/.well-known/silique') {
            return http.Response(
              jsonEncode({
                'api_version': '1',
                'features': {'image_attachments': true},
              }),
              200,
            );
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$')
              .hasMatch(path)) {
            uploadedChunks.add(path);
            return http.Response('{}', 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
              request.method == 'PUT') {
            uploadedManifests.add(path);
            return http.Response('{}', 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            if (uploadedManifests.isEmpty) {
              return http.Response(
                jsonEncode({'error': 'Image not uploaded yet'}),
                409,
              );
            }
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            acceptedBatches.addAll(ids);
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
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

      // The image was uploaded (chunks + manifest) before the batch was accepted.
      expect(uploadedChunks, isNotEmpty);
      expect(uploadedManifests, isNotEmpty);
      expect(acceptedBatches, isNotEmpty);
      expect(repo.syncIssues, isEmpty);
      // After a successful sync the image asset is acked again locally.
      expect(repo.storage.imageAsset(vault.id, imageId)!['uploaded'], 1);
    },
  );

  test(
    'a 409 "Image not uploaded yet" self-heals by re-uploading the image and '
    'retrying the batch once',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-8-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      final reference = await repo.addImage(
        vault.id,
        note.id,
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
        'image/png',
      );
      final imageId = reference.split(':').last;
      await repo.save(note.copyWith(body: '![photo]($reference)'));
      // The client THINKS the image is uploaded (acked), but the server lost it.
      repo.storage.markImageUploaded(vault.id, imageId);

      // The vault is already owned by this account on this server, so sync does
      // NOT rebind (which would re-mark images pending); it pushes directly.
      // The revision is pending, but the image is acked.
      vault.owner = 'current-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      var batchCount = 0;
      var manifestsSeen = 0;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          requests.add('${request.method} ${request.url.path}');
          final path = request.url.path;
          if (path == '/.well-known/silique') {
            return http.Response(
              jsonEncode({
                'api_version': '1',
                'features': {'image_attachments': true},
              }),
              200,
            );
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
              request.method == 'PUT') {
            manifestsSeen++;
            return http.Response('{}', 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$').hasMatch(path)) {
            return http.Response('{}', 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            batchCount++;
            // First batch is rejected before the manifest exists on the server,
            // even though the client believes the image was already uploaded.
            if (manifestsSeen == 0) {
              return http.Response(
                jsonEncode({'error': 'Image not uploaded yet'}),
                409,
              );
            }
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
              200,
            );
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      await expectLater(repo.sync(), completes);
      expect(batchCount, 2);
      expect(manifestsSeen, 1);
      expect(repo.storage.imageAsset(vault.id, imageId)!['uploaded'], 1);
    },
  );

  test(
    'recovery from "Parent revision missing" also re-uploads the image',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-9-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      final reference = await repo.addImage(
        vault.id,
        note.id,
        Uint8List.fromList(List<int>.generate(64, (i) => i)),
        'image/png',
      );
      final imageId = reference.split(':').last;
      await repo.save(note.copyWith(body: 'two'));
      // Image is believed uploaded; the revision was acked on the old server.
      repo.storage.markImageUploaded(vault.id, imageId);
      repo.storage.atomic(
        () => repo.storage.acknowledge(
          vault.id,
          repo.storage.revisions(vault.id).map((r) => r.id).toList(),
        ),
      );
      expect(repo.storage.pending(vault.id), isEmpty);

      // Fresh server: rebind marks everything pending. Then the first batch
      // references a parent the server has never seen.
      vault.owner = 'https://inny.serwer|inny-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final uploadedManifests = <String>[];
      var batchCount = 0;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/.well-known/silique') {
            return http.Response(
              jsonEncode({
                'api_version': '1',
                'features': {'image_attachments': true},
              }),
              200,
            );
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
              request.method == 'PUT') {
            uploadedManifests.add(path);
            return http.Response('{}', 200);
          }
          if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$').hasMatch(path)) {
            return http.Response('{}', 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            batchCount++;
            if (batchCount == 1) {
              return http.Response(
                jsonEncode({'error': 'Parent revision missing'}),
                409,
              );
            }
            final body = jsonDecode(request.body) as Json;
            final ids = (body['revisions'] as List)
                .map((r) => (r as Json)['id'] as String)
                .toList();
            return http.Response(
              jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
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

      // The image was re-uploaded as part of the recovery path.
      expect(uploadedManifests, isNotEmpty);
      expect(repo.syncIssues, isEmpty);
      expect(repo.storage.imageAsset(vault.id, imageId)!['uploaded'], 1);
    },
  );

  test(
    'markAllImagesPending zeroes uploaded for the target vault only',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-switch-10-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Pierwszy');
      await repo.createVault('Drugi');
      final a = repo.vaults[0].id;
      final b = repo.vaults[1].id;
      final noteA = await repo.createNote(a);
      final noteB = await repo.createNote(b);

      const manifest = '{}';
      final idA = '11111111-1111-1111-1111-111111111111';
      final idB = '22222222-2222-2222-2222-222222222222';

      // Mark both images uploaded, in two different vaults.
      repo.storage.putImageAsset(
        a,
        noteA.id,
        idA,
        manifest,
        uploaded: true,
      );
      repo.storage.putImageAsset(
        b,
        noteB.id,
        idB,
        manifest,
        uploaded: true,
      );
      expect(repo.storage.imageAsset(a, idA)!['uploaded'], 1);
      expect(repo.storage.imageAsset(b, idB)!['uploaded'], 1);

      repo.storage.markAllImagesPending(a);

      // Only vault A's image is now pending (uploaded=0).
      expect(repo.storage.imageAsset(a, idA)!['uploaded'], 0);
      expect(repo.storage.pendingImages(a), hasLength(1));
      // Vault B is untouched.
      expect(repo.storage.imageAsset(b, idB)!['uploaded'], 1);
      expect(repo.storage.pendingImages(b), isEmpty);
    },
  );
}
