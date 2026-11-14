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

Map<String, dynamic> _keyWrap(Notebook repo, Vault vault) =>
    jsonDecode(vault.keyWrap) as Map<String, dynamic>;

void main() {
  test(
    'rebind assigns a new vault to the account with expectedVersion 0',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-rebind-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.owner = 'https://old.example|old-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final requests = <String>[];
      int? putExpectedVersion;
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
            putExpectedVersion =
                (jsonDecode(request.body) as Json)['expectedVersion'] as int?;
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (path.endsWith('/changes')) {
            return http.Response(
              jsonEncode({
                'purged': <Object>[],
                'revisions': <Object>[],
                'cursor': 0,
                'hasMore': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.rebindVault(vault);

      expect(requests, contains('PUT /v1/vaults/${vault.id}'));
      expect(putExpectedVersion, 0);
      final stored = repo.vaults.single;
      expect(stored.owner, repo.session!.owner);
      expect(stored.syncEnabled, isTrue);
      final wrap = _keyWrap(repo, stored);
      expect(wrap['mode'], 'account');
      final unwrapped = base64Decode(
        await repo.crypto.open(
          repo.accountKey!,
          wrap['wrapped'] as String,
          'silique:2:vault-key:${stored.id}',
        ),
      );
      expect(unwrapped, repo.unlocked[stored.id]);
    },
  );

  test(
    'rebind of a server-known vault uses the live server version',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-rebind-v-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.version = 3;
      vault.owner = 'https://old.example|old-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      int? putExpectedVersion;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({
                'vaults': [
                  {'id': vault.id, 'version': 7},
                ],
                'deletedVaults': <Object>[],
              }),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            putExpectedVersion =
                (jsonDecode(request.body) as Json)['expectedVersion'] as int?;
            return http.Response(jsonEncode({'version': 8}), 200);
          }
          if (path.endsWith('/changes')) {
            return http.Response(
              jsonEncode({
                'purged': <Object>[],
                'revisions': <Object>[],
                'cursor': 0,
                'hasMore': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await repo.rebindVault(vault);

      expect(putExpectedVersion, 7);
      expect(repo.vaults.single.version, 8);
    },
  );

  test(
    'a 410 vault_deleted surfaces the tombstone message and keeps local notes',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-rebind-410-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(body: 'Lokalna treść do zachowania'));
      expect(repo.storage.documents(vault.id), isNotEmpty);
      expect(repo.storage.isVaultDeleted(vault.id), isFalse);

      vault.owner = 'https://old.example|old-user';
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
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(
              jsonEncode({'error': 'vault_deleted'}),
              410,
              request: request,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      await expectLater(
        repo.rebindVault(vault),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('usunięty na serwerze'),
          ),
        ),
      );

      // The failed rebind must not adopt the new owner nor erase local notes.
      final stored = repo.vaults.single;
      expect(stored.owner, 'https://old.example|old-user');
      expect(stored.syncEnabled, isTrue);
      expect(repo.storage.isVaultDeleted(vault.id), isFalse);
      expect(repo.storage.documents(vault.id), isNotEmpty);
      expect(repo.notes[vault.id]!.containsKey(note.id), isTrue);
    },
  );
}