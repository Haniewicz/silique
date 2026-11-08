import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:uuid/uuid.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  for (final shape in [
    'direct-missing',
    'hidden-newer-base',
    'missing-older-history',
  ]) {
    final hiddenNewerBase = shape == 'hidden-newer-base';
    final olderHistory = shape == 'missing-older-history';
    for (final bodies
        in olderHistory
            ? [
                ['ONE\ntwo', 'one\nTWO'],
              ]
            : [
                ['left', 'right'],
                ['', 'right'],
                ['right', ''],
              ]) {
      test(
        'partial history ($shape) preserves visible alternatives $bodies',
        () async {
          final dir = Directory.systemTemp.createTempSync('sync-missing-base-');
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
          await repo.createVault('partial history');
          final vault = repo.vaults.single;
          repo.session = Session(
            server: 'http://127.0.0.1',
            token: 'fixture',
            userId: 'fixture',
            email: 'fixture@example.com',
          );
          repo.accountKey = repo.crypto.randomKey();
          vault.owner = repo.session!.owner;
          vault.syncEnabled = true;
          repo.storage.putVault(vault);
          var batches = 0;
          repo.api = SiliqueApi(
            'http://127.0.0.1',
            client: MockClient((r) async {
              if (r.method == 'GET' && r.url.path == '/v1/vaults') {
                return http.Response('{"vaults":[]}', 200);
              }
              if (r.method == 'GET' && r.url.path.endsWith('/changes')) {
                return http.Response(
                  '{"revisions":[],"cursor":0,"hasMore":false}',
                  200,
                );
              }
              if (r.method == 'POST' && r.url.path.endsWith('/batches')) {
                batches++;
                final body = jsonDecode(r.body) as Json;
                return http.Response(
                  jsonEncode({
                    'batchId': body['batchId'],
                    'accepted': (body['revisions'] as List)
                        .map((v) => v['id'])
                        .toList(),
                  }),
                  200,
                );
              }
              throw StateError('Unexpected request ${r.method} ${r.url.path}');
            }),
          );
          const uuid = Uuid();
          final noteId = uuid.v4(), unavailable = uuid.v4();
          String id(int index) =>
              '${noteId.substring(0, 24)}${index.toString().padLeft(12, '0')}';
          final history = <({String id, String body, List<String> parents})>[
            if (olderHistory)
              (id: id(0), body: 'one\ntwo', parents: [unavailable]),
            if (hiddenNewerBase) ...[
              (id: id(0), body: '', parents: <String>[]),
              (id: id(1), body: 'base', parents: [id(0)]),
            ],
            for (final (index, body) in bodies.indexed)
              (
                id: id(index + 4),
                body: body,
                parents: olderHistory
                    ? [id(0)]
                    : hiddenNewerBase
                    ? index == 0
                          ? [unavailable, id(0)]
                          : [id(1)]
                    : [unavailable],
              ),
          ];
          // With hiddenNewerBase, missing M would parent X=id(1); A parents
          // [M,R] and B parents [X]. Its absent edges hide X as a newer base.
          for (final entry in history) {
            final note = Note(
              id: noteId,
              vaultId: vault.id,
              title: 'partial history',
              body: entry.body,
              updatedAt: DateTime.utc(2026),
            );
            final revision = Revision(
              id: entry.id,
              vaultId: vault.id,
              noteId: noteId,
              parents: entry.parents,
              payload: '',
            );
            repo.storage.putRevision(
              Revision(
                id: revision.id,
                vaultId: vault.id,
                noteId: noteId,
                parents: revision.parents,
                payload: await repo.crypto.seal(
                  repo.unlocked[vault.id]!,
                  jsonEncode(note.toJson()),
                  revision.aad,
                ),
              ),
            );
          }
          final immutable = repo.storage
              .revisions(vault.id)
              .map((r) => r.toWire())
              .toList();
          await repo.sync();
          expect(
            repo.notes[vault.id]!.values.map((n) => n.body).toSet(),
            olderHistory ? {'ONE\nTWO'} : bodies.toSet(),
          );
          expect(repo.storage.pending(vault.id), isEmpty);
          final settled = batches;
          await repo.sync();
          await repo.sync();
          expect(
            batches,
            settled,
            reason: 'Partial histories must not generate endless merge batches',
          );
          final stored = {
            for (final r in repo.storage.revisions(vault.id)) r.id: r.toWire(),
          };
          for (final original in immutable) {
            expect(
              stored[original['id']],
              original,
              reason: 'Existing encrypted history is immutable',
            );
          }
        },
      );
    }
  }
}
