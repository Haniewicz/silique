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

void main() {
  test(
    'a re-upload splits revisions so no batch exceeds the server limit of 100',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-batch-limit-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      vault.syncEnabled = true;
      // Unbound vault: it must sync without any owner ceremony.
      expect(vault.owner, isNull);
      repo.storage.putVault(vault);

      final note = await repo.createNote(vault.id);
      // 105 pending revisions: one more than the server accepts in a batch.
      for (var i = 0; i < 105; i++) {
        await repo.save(note.copyWith(body: 'wersja $i'));
      }

      final batchSizes = <int>[];
      final sentIds = <String>{};
      var rejectOverLimit = 0;
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          if (path == '/v1/vaults') {
            // A fresh server that knows neither the vault nor its revisions:
            // the client must create it and re-upload the whole chain.
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path == '/v1/vaults/${vault.id}') {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final revisions = (body['revisions'] as List).cast<Object>();
            batchSizes.add(revisions.length);
            if (revisions.length > 100) {
              // Mirror the server's Zod `.max(100)`: over-limit batches fail.
              rejectOverLimit++;
              return http.Response(
                jsonEncode({'error': 'Invalid request'}),
                400,
              );
            }
            sentIds.addAll(
              revisions.map((r) => (r as Map<String, dynamic>)['id'] as String),
            );
            return http.Response(
              jsonEncode({
                'accepted': revisions
                    .map((r) => (r as Map<String, dynamic>)['id'])
                    .toList(),
                'batchId': body['batchId'],
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

      // One pass sends at most one batch per push phase; repeat until the
      // queue drains, exactly as the wakeup loop does in the app.
      for (var pass = 0; pass < 5 && sentIds.length < 106; pass++) {
        await repo.sync();
      }

      expect(rejectOverLimit, 0, reason: 'partie: $batchSizes');
      expect(
        batchSizes.every((size) => size <= 100),
        isTrue,
        reason: 'partie: $batchSizes',
      );
      expect(
        sentIds.length,
        106,
        reason: 'wysłane rewizje: ${sentIds.length}, partie: $batchSizes',
      );
    },
  );
}