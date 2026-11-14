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
    'an owner-mismatch vault is recorded in syncIssues while a matching vault is not',
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

      final foreignIssue = repo.syncIssues
          .where((issue) => issue.vaultId == foreign.id)
          .toList();
      expect(foreignIssue, hasLength(1));
      expect(foreignIssue.single.reason, SyncIssue.ownerMismatch);
      expect(foreignIssue.single.owner, 'https://old.example|old-user');
      expect(foreignIssue.single.sessionOwner, repo.session!.owner);
      expect(
        requests,
        isNot(contains('GET /v1/vaults/${foreign.id}/changes')),
        reason: 'the skipped vault must not send a single change request',
      );

      expect(
        repo.syncIssues.where((issue) => issue.vaultId == matched.id),
        isEmpty,
        reason: 'a correctly-owned vault must not generate a skip entry',
      );
    },
  );
}