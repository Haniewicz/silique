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

void main() {
  test(
    'a foreign-owner vault re-binds automatically and no vault emits a skip entry',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-sync-issue-');
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.initialize();
      repo.session = Session(
        server: _server,
        token: 'test',
        userId: 'current-user',
        email: 'a@example.invalid',
      );
      repo.accountKey = repo.crypto.randomKey();
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
          if (request.method == 'PUT' && path.startsWith('/v1/vaults/')) {
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

      await repo.createVault('Z obcym właścicielem');
      final foreign = repo.vaults.single;
      foreign.owner = 'https://old.example|old-user';
      foreign.syncEnabled = true;
      repo.storage.putVault(foreign);

      await repo.createVault('Poprawny');
      final matched = repo.vaults.last;
      matched.owner = repo.session!.owner;
      matched.syncEnabled = true;
      repo.storage.putVault(matched);

      await repo.sync();

      // Ownership is provenance, not a gate: the foreign vault is re-bound
      // instead of being skipped, so neither vault produces a skip entry.
      expect(
        repo.syncIssues.where((issue) => issue.vaultId == foreign.id),
        isEmpty,
      );
      expect(
        repo.syncIssues.where((issue) => issue.vaultId == matched.id),
        isEmpty,
      );
      expect(requests, contains('PUT /v1/vaults/${foreign.id}'));
      expect(
        repo.vaults.firstWhere((v) => v.id == foreign.id).owner,
        repo.session!.owner,
      );
    },
  );

  test(
    'a vault listed in deletedVaults for another account is flagged tombstoned, never recreated',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-sync-tomb-');
      final repo = Notebook(
        storage: NativeStorage(dir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.initialize();
      repo.session = Session(
        server: _server,
        token: 'test',
        userId: 'current-user',
        email: 'a@example.invalid',
      );
      repo.accountKey = repo.crypto.randomKey();

      await repo.createVault('Obcy, usunięty');
      final vault = repo.vaults.single;
      final vaultId = vault.id;
      vault.owner = 'https://old.example|old-user';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);

      final puts = <String>[];
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (request.method == 'PUT') {
            puts.add(path);
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({
                'vaults': <Object>[],
                'deletedVaults': <Object>[vaultId],
              }),
              200,
            );
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

      await repo.sync();

      final issue = repo.syncIssues.where((i) => i.vaultId == vaultId).toList();
      expect(issue, hasLength(1));
      expect(issue.single.reason, SyncIssue.tombstoned);
      expect(issue.single.owner, 'https://old.example|old-user');
      // No silent recreation under the retired ID.
      expect(puts, isNot(contains('/v1/vaults/$vaultId')));
      // Local notes/key remain untouched.
      expect(repo.storage.isVaultDeleted(vaultId), isFalse);
      expect(repo.vaults.single.id, vaultId);
    },
  );
}