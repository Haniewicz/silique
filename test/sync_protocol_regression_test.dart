import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _SnapshotBarrier {
  int arrivals = 0;
  final ready = Completer<void>();
  Future<void> wait() async {
    if (++arrivals == 2) ready.complete();
    await ready.future.timeout(const Duration(seconds: 5));
  }
}

class _WireCounter extends http.BaseClient {
  final inner = http.Client();
  _SnapshotBarrier? barrier;
  int requests = 0, batches = 0, rateLimits = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    if (request.url.path.endsWith('/batches')) batches++;
    final response = await inner.send(request);
    if (response.statusCode == 429) rateLimits++;
    if (request.url.path.endsWith('/changes') && barrier != null) {
      final bytes = await response.stream.toBytes();
      await barrier!.wait();
      return http.StreamedResponse(
        Stream.value(bytes),
        response.statusCode,
        headers: response.headers,
      );
    }
    return response;
  }

  @override
  void close() => inner.close();
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  for (final scenario in [
    (name: 'left/right', root: 'base', resolution: 'left'),
    (name: 'older-base/right', root: 'base', resolution: 'base'),
    (name: 'intentional-empty/right', root: 'base', resolution: ''),
    (name: 'older-empty/right', root: '', resolution: ''),
  ]) {
    test(
      'criss-cross ${scenario.name} histories preserve resolutions regardless of local insertion order',
      () async {
        final dirs = List.generate(
          2,
          (_) => Directory.systemTemp.createTempSync('sync-criss-cross-'),
        );
        final clients = [
          for (final dir in dirs)
            Notebook(
              storage: NativeStorage(dir.path),
              keys: MemoryKeys(),
              crypto: TestCrypto(),
            ),
        ];
        final counters = List.generate(2, (_) => _WireCounter());
        addTearDown(() async {
          for (final client in clients) {
            await client.close();
          }
          for (final dir in dirs) {
            dir.deleteSync(recursive: true);
          }
        });
        final a = clients[0], b = clients[1];
        for (final client in clients) {
          await client.initialize();
        }
        final email =
            'criss-cross-${DateTime.now().microsecondsSinceEpoch}@example.com';
        const password = 'disposable criss-cross test password';
        final recovery = await a.connect(
          server!,
          email,
          password,
          register: true,
        );
        await a.createVault('conflict regression');
        final vault = a.vaults.single;
        await a.enableSync(vault);
        final note = await a.createNote(vault.id);
        await a.save(note.copyWith(body: scenario.root));
        await a.sync();
        await b.connect(server, email, password, recoveryKey: recovery);
        await b.sync();
        final root = a.heads(vault.id, note.id).single;
        final namespace = const Uuid().v4().substring(0, 24);
        Future<Revision> revision(
          int id,
          String body,
          List<String> parents,
        ) async {
          final r = Revision(
            id: '$namespace${id.toString().padLeft(12, '0')}',
            vaultId: vault.id,
            noteId: note.id,
            parents: parents,
            payload: '',
          );
          return Revision(
            id: r.id,
            vaultId: r.vaultId,
            noteId: r.noteId,
            parents: parents,
            payload: await a.crypto.seal(
              a.unlocked[vault.id]!,
              jsonEncode(note.copyWith(body: body).toJson()),
              r.aad,
            ),
          );
        }

        // A historical resolution may deliberately restore an older or empty body.
        // Neither is an authoritative base for two incomparable resolutions.
        final left = await revision(11, 'left', [root.id]);
        final right = await revision(12, 'right', [root.id]);
        final m1 = await revision(21, scenario.resolution, [left.id, right.id]);
        final m2 = await revision(22, 'right', [left.id, right.id]);
        final history = [left, right, m1, m2];
        final known = [root, ...history];
        await a.api!.request(
          'POST',
          '/v1/vaults/${vault.id}/batches',
          body: {
            'batchId': '${namespace}000000000030',
            'revisions': history.map((r) => r.toWire()).toList(),
          },
        );
        for (final r in history) {
          a.storage.putRevision(r);
        }
        for (final r in [right, left, m2, m1]) {
          b.storage.putRevision(r);
        }
        for (var i = 0; i < clients.length; i++) {
          clients[i].api!.close();
          clients[i].api = SiliqueApi(
            server,
            token: clients[i].session!.token,
            client: counters[i],
          );
        }
        Future<void> round() async {
          final barrier = _SnapshotBarrier();
          for (final counter in counters) {
            counter.barrier = barrier;
          }
          await Future.wait(clients.map((c) => c.sync()));
        }

        await round();
        // ignore: avoid_print
        print(
          'CRISS-CROSS FIRST ROUND: A=${a.notes[vault.id]![note.id]!.body}, B=${b.notes[vault.id]![note.id]!.body}',
        );
        expect(
          a.notes[vault.id]![note.id]!.body,
          b.notes[vault.id]![note.id]!.body,
          reason: 'Choosing a merge base by SQLite insertion order makes opposite resolutions',
        );
        for (var i = 0; i < 4; i++) {
          await round();
        }
        final before = counters.fold<int>(0, (n, c) => n + c.batches);
        await round();
        await round();
        final after = counters.fold<int>(0, (n, c) => n + c.batches);
        expect(
          after,
          before,
          reason: 'Settled conflict histories must not send further batches',
        );
        for (final client in clients) {
          expect(client.storage.pending(vault.id), isEmpty);
          expect(
            client.notes[vault.id]!.values.map((n) => n.body).toSet(),
            {scenario.resolution, 'right'},
            reason: 'Both conflicting contents must remain visible, not merely in history',
          );
          expect(
            client.notes[vault.id]!.length,
            2,
            reason: 'No conflict-copy multiplication',
          );
          final stored = {
            for (final r in client.storage.revisions(vault.id))
              r.id: r.toWire(),
          };
          for (final r in known) {
            expect(
              stored[r.id],
              r.toWire(),
              reason:
                  'Known revision IDs, parents and ciphertext remain immutable',
            );
          }
        }
        // ignore: avoid_print
        print(
          'CRISS-CROSS ${scenario.name} HTTP PROOF: requests=${counters.fold<int>(0, (n, c) => n + c.requests)}, batches=$after, lastTwoRoundsBatches=${after - before}, HTTP429=${counters.fold<int>(0, (n, c) => n + c.rateLimits)}, outboxes=${clients.map((c) => c.storage.pending(vault.id).length).toList()}, visible=${jsonEncode(a.notes[vault.id]!.values.map((n) => n.body).toList())}, immutableKnownRevisions=${known.length}',
        );
      },
      skip: server == null ? 'Set disposable SILIQUE_TEST_SERVER' : false,
    );
  }
}
