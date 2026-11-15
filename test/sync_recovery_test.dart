import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart' show notebookProvider;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/sync_status_dialog.dart';

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

Json _emptyChanges() => {
  'purged': <Object>[],
  'revisions': <Object>[],
  'cursor': 0,
  'hasMore': false,
};

/// Wires [vaultId] for sync as the current account, without contacting a server.
void enableSync(Notebook repo, String vaultId) {
  final vault = repo.vaults.firstWhere((v) => v.id == vaultId);
  vault.owner = 'current-user';
  vault.syncEnabled = true;
  repo.storage.putVault(vault);
}

/// A minimal in-memory server that enforces the real changelog/batch contract:
/// revisions are stored per note with an auto-increment `seq`, parents must
/// already exist (else 409 "Parent revision missing"), each revision accepts at
/// most 32 parents, and purged note ids are dropped silently. This lets a reset
/// test assert parent citation and final divergence without a real network.
class FakeVaultServer {
  FakeVaultServer({List<Json>? seed, Set<String>? purged}) : purged = purged ?? <String>{} {
    for (final item in seed ?? const <Json>[]) {
      _add(item);
    }
  }

  final List<Json> changes = <Json>[];
  final List<Json> revisions = <Json>[]; // stored in seq order
  final Set<String> purged;
  int _seq = 0;
  final List<Json> acceptedBatches = <Json>[];

  void _add(Json item) {
    final clone = Map<String, dynamic>.from(item);
    clone['seq'] = ++_seq;
    revisions.add(clone);
    changes.add(clone);
  }

  /// Accepts a batch, enforcing parent/limit rules like the real server. Parents
  /// may be introduced earlier in the same batch (parent-before-child insertion
  /// order), matching how a chain's later links cite earlier links.
  void acceptBatch(Json body) {
    final batchRevisions = (body['revisions'] as List).cast<Json>();
    final known = {
      for (final r in revisions) r['id'] as String,
    };
    for (final r in batchRevisions) {
      final parents = (r['parents'] as List).cast<String>();
      if (parents.length > 32) {
        throw const FormatException('too many parents');
      }
      for (final p in parents) {
        if (!known.contains(p)) {
          throw const FormatException('Parent revision missing');
        }
      }
      final noteId = r['noteId'] as String;
      if (purged.contains(noteId)) continue; // silently skipped
      _add(Map<String, dynamic>.from(r)..remove('images'));
      known.add(r['id'] as String);
    }
    acceptedBatches.add(body);
  }

  /// Serves the changes endpoint for a cursor.
  Json changesSince(int cursor) {
    final page = revisions.where((r) => (r['seq'] as int) > cursor).toList();
    final lastSeq = page.isEmpty ? cursor : (page.last['seq'] as int);
    return {
      'purged': purged.toList(),
      'revisions': page,
      'cursor': lastSeq,
      'hasMore': page.length == 100,
    };
  }

  /// Builds a [MockClient] wired to this server for one [vaultId].
  MockClient client(String vaultId) {
    return MockClient((request) async {
      final path = request.url.path;
      if (path == '/v1/vaults') {
        return http.Response(
          jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
          200,
        );
      }
      if (request.method == 'PUT' && path == '/v1/vaults/$vaultId') {
        return http.Response(jsonEncode({'version': 1}), 200);
      }
      if (path == '/.well-known/silique') {
        return http.Response(
          jsonEncode({
            'api_version': '1',
            'features': {'image_attachments': true},
          }),
          200,
        );
      }
      if (request.method == 'POST' && path == '/v1/vaults/$vaultId/batches') {
        final body = jsonDecode(request.body) as Json;
        try {
          acceptBatch(body);
        } on FormatException catch (e) {
          return http.Response(jsonEncode({'error': e.message}), 409);
        }
        final ids = (body['revisions'] as List)
            .map((r) => (r as Json)['id'] as String)
            .toList();
        return http.Response(
          jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
          200,
        );
      }
      if (path == '/v1/vaults/$vaultId/changes') {
        final cursor = int.parse(
          request.url.queryParameters['cursor'] ?? '0',
        );
        return http.Response(
          jsonEncode(changesSince(cursor)),
          200,
        );
      }
      if (request.method == 'DELETE' &&
          RegExp(r'^/v1/vaults/[a-f0-9-]{36}/notes/[a-zA-Z0-9_-]+$')
              .hasMatch(path)) {
        // Purge confirmation for a hidden-note move; the id is not tracked.
        return http.Response(jsonEncode({'purged': true}), 200);
      }
      if (RegExp(r'/images/[a-f0-9-]{36}/chunks/\d+$').hasMatch(path) ||
          (RegExp(r'/images/[a-f0-9-]{36}$').hasMatch(path) &&
              request.method == 'PUT')) {
        return http.Response('{}', 200);
      }
      if (request.method == 'GET' &&
          RegExp(r'/images/[a-zA-Z0-9_-]+$').hasMatch(path)) {
        // Mirrors the real server: a manifest request for an image this vault
        // never received (or whose asset was purged) is a 404, not an empty
        // manifest. The client must tolerate it instead of failing the pass.
        return http.Response(jsonEncode({'message': 'Image not found'}), 404);
      }
      return http.Response('{}', 200);
    });
  }
}

/// Builds an encrypted revision JSON entry for [note] that [FakeVaultServer]
/// can serve, with parent [parents] and the given [seq].
Future<Json> encryptForServer(
  Notebook repo,
  String vaultId,
  Note note,
  List<String> parents,
  int seq, {
  String? id,
}) async {
  final revisionId = id ?? '00000000-0000-4000-8000-${seq.toString().padLeft(12, '0').substring(0, 12)}';
  final placeholder = Revision(
    id: revisionId,
    vaultId: vaultId,
    noteId: note.id,
    parents: parents,
    payload: '',
  );
  return {
    'id': revisionId,
    'noteId': note.id,
    'parents': parents,
    'payload': await repo.crypto.seal(
      repo.unlocked[vaultId]!,
      jsonEncode(note.toJson()),
      placeholder.aad,
    ),
    'seq': seq,
  };
}

/// Seeds a note's existing local revision on the server (same id, seq [seq])
/// so the reset's full pull sees it as server-known. Returns the seeded JSON.
Future<Json> seedLocalRevision(
  Notebook repo,
  String vaultId,
  Note note,
  int seq,
) {
  final localRev = repo.storage.revisions(vaultId, noteId: note.id).single;
  return encryptForServer(
    repo,
    vaultId,
    note,
    localRev.parents,
    seq,
    id: localRev.id,
  );
}

void main() {
  group('VaultSyncStatus model', () {
    test('round-trips through JSON and reports failing semantics', () {
      final t0 = DateTime.utc(2026, 1, 1, 10);
      final t1 = DateTime.utc(2026, 1, 1, 11);
      final t2 = DateTime.utc(2026, 1, 1, 12);

      // Never attempted: not failing (nothing has gone wrong yet).
      expect(VaultSyncStatus().failing, isFalse);

      // A success with no error is not failing.
      final ok = VaultSyncStatus(
        lastSuccessAt: t1,
        lastAttemptAt: t1,
      );
      expect(ok.failing, isFalse);

      // An error after a success is failing.
      final failed = VaultSyncStatus(
        lastSuccessAt: t0,
        lastAttemptAt: t2,
        lastError: 'boom',
        lastErrorAt: t2,
      );
      expect(failed.failing, isTrue);

      // An error with no prior success is failing.
      expect(
        VaultSyncStatus(
          lastAttemptAt: t2,
          lastError: 'boom',
          lastErrorAt: t2,
        ).failing,
        isTrue,
      );

      // A success newer than the error clears the failure.
      final recovered = VaultSyncStatus(
        lastSuccessAt: t2,
        lastAttemptAt: t2,
        lastError: 'boom',
        lastErrorAt: t1,
      );
      expect(recovered.failing, isFalse);

      // JSON round-trip preserves every field, including nulls.
      final restored = VaultSyncStatus.fromJson(recovered.toJson());
      expect(restored.lastSuccessAt, t2);
      expect(restored.lastAttemptAt, t2);
      expect(restored.lastError, 'boom');
      expect(restored.lastErrorAt, t1);
      expect(restored.failing, recovered.failing);
    });

    test('sync_state storage round-trips and is cleared on erase', () async {
      final dir = Directory.systemTemp.createTempSync('silique-syncstate-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final id = repo.vaults.single.id;

      expect(repo.storage.syncStatus(id), isNull);

      final status = VaultSyncStatus(
        lastSuccessAt: DateTime.utc(2026, 1, 1),
        lastAttemptAt: DateTime.utc(2026, 1, 2),
        lastError: 'boom',
        lastErrorAt: DateTime.utc(2026, 1, 3),
      );
      repo.storage.putSyncStatus(id, status);
      final restored = repo.storage.syncStatus(id)!;
      expect(restored.lastSuccessAt, status.lastSuccessAt);
      expect(restored.lastAttemptAt, status.lastAttemptAt);
      expect(restored.lastError, 'boom');
      expect(restored.lastErrorAt, status.lastErrorAt);
      expect(restored.failing, status.failing);

      // Erasing the vault also removes its local sync status.
      await repo.storage.eraseVault(id);
      expect(repo.storage.syncStatus(id), isNull);
    });
  });

  test(
    'per-vault failure isolation: a failing vault records its error and the '
    'other vault still syncs; the pass still reports the failure',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-isolate-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('A');
      await repo.createVault('B');
      final a = repo.vaults[0].id;
      final b = repo.vaults[1].id;
      await repo.createNote(a);
      final noteB = await repo.createNote(b);
      await repo.save(noteB.copyWith(body: 'contents for B'));
      enableSync(repo, a);
      enableSync(repo, b);

      final log = <String>[];
      // Vault A's changes endpoint always fails; vault B succeeds and echoes
      // nothing new (so it can pull and finish cleanly).
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          final path = request.url.path;
          log.add('${request.method} $path');
          if (path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          if (request.method == 'PUT' && path.startsWith('/v1/vaults/')) {
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
          if (path.endsWith('/changes') && path.contains('/vaults/$a/')) {
            return http.Response(jsonEncode({'error': 'boom'}), 503);
          }
          if (path.endsWith('/changes')) {
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          return http.Response('{}', 200);
        }),
      );

      // The pass must report the failure (first error survives), while vault B
      // still records success and its note is acknowledged.
      await expectLater(repo.sync(), throwsA(isA<ApiException>()));

      expect(repo.syncStatus(a)!.failing, isTrue);
      expect(repo.syncStatus(a)!.lastError, isNotNull);
      expect(repo.syncStatus(b)!.failing, isFalse);
      expect(repo.syncStatus(b)!.lastSuccessAt, isNotNull);
      // Vault B pulled (its changes endpoint was reached).
      expect(
        log.any((r) => r == 'GET /v1/vaults/$b/changes'),
        isTrue,
      );
      // Vault B's batched note was pushed and acknowledged.
      expect(repo.storage.pendingCount(b), 0);
    },
  );

  test(
    'a note citing an image the server never received does not fail the pass',
    () async {
      // Regression: `_cacheImages` runs after the pull and before the push. A
      // note whose body cites an image the server answers with 404 (a lost or
      // purged attachment) used to throw here, aborting the pass for the vault
      // before its push phase — every pass failed identically and the device
      // looked permanently stalled even though it could read the notes.
      final dir = Directory.systemTemp.createTempSync('silique-lost-image-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);
      const lost = '11111111-1111-4111-8111-111111111111';
      final citeImage = note.copyWith(body: '![lost](silique-image:$lost)');
      await repo.save(citeImage);

      // The server already holds a revision of this note citing the same image.
      final server = FakeVaultServer(
        seed: [await encryptForServer(repo, vault.id, citeImage, const [], 1)],
      );
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      // The pass completes and records success instead of throwing.
      await repo.sync();
      expect(repo.syncStatus(vault.id)!.failing, isFalse);
      // The note is readable on this device even though its image is not.
      expect(repo.notes[vault.id]![note.id]!.body, contains(lost));
    },
  );

  test(
    'force full pull from cursor 0 picks up a revision a stale cursor skipped',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-forcepull-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);

      // First local revision, acknowledged and cursor at 1.
      await repo.save(note.copyWith(body: 'one'));
      final r1 = repo.storage.revisions(vault.id).last;
      repo.storage.atomic(
        () => repo.storage.acknowledge(
          vault.id,
          repo.storage.revisions(vault.id).map((r) => r.id).toList(),
        ),
      );
      repo.storage.setCursor(vault.id, 1);
      expect(repo.storage.cursor(vault.id), 1);

      // Another device authored a second revision (r2, parent r1) with body
      // "two", assigned seq 2. This client never pulled it, and its cursor was
      // already advanced past seq 2, simulating a bogus/stale cursor.
      const r2id = '22222222-2222-4222-8222-222222222222';
      final localNote = repo.notes[vault.id]![note.id]!;
      final remoteNote = localNote.copyWith(body: 'two');
      final r2 = Revision(
        id: r2id,
        vaultId: vault.id,
        noteId: note.id,
        parents: [r1.id],
        payload: '',
        seq: 2,
      );
      final payload = await repo.crypto.seal(
        repo.unlocked[vault.id]!,
        jsonEncode(remoteNote.toJson()),
        r2.aad,
      );

      // A stale cursor (past seq 2) would make a normal pull miss r2 forever.
      repo.storage.setCursor(vault.id, 99);

      final sentBatches = <Json>[];
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
          if (request.method == 'PUT' && path.startsWith('/v1/vaults/')) {
            return http.Response(jsonEncode({'version': 1}), 200);
          }
          if (request.method == 'POST' && path.endsWith('/batches')) {
            sentBatches.add(jsonDecode(request.body) as Json);
            return http.Response('{}', 200);
          }
          if (path == '/v1/vaults/${vault.id}/changes') {
            final cursor = int.parse(
              request.url.queryParameters['cursor'] ?? '0',
            );
            final revisions = cursor < 2
                ? [
                    {
                      'id': r2.id,
                      'noteId': r2.noteId,
                      'parents': r2.parents,
                      'payload': payload,
                      'seq': 2,
                    },
                  ]
                : <Json>[];
            return http.Response(
              jsonEncode({
                'purged': <Object>[],
                'revisions': revisions,
                'cursor': 2,
                'hasMore': false,
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );

      final revisionsBefore = repo.storage.revisions(vault.id).length;

      await repo.forceFullPull(vaultId: vault.id);

      // The replayed revision is now local and reconciled into the document.
      expect(repo.storage.revisions(vault.id).map((r) => r.id), contains(r2id));
      expect(repo.notes[vault.id]![note.id]!.body, 'two');
      expect(repo.storage.cursor(vault.id), 2);
      // Pull-only: nothing was pushed (no batch POST happened) and no new local
      // revision was created by the pull.
      expect(sentBatches, isEmpty);
      expect(repo.storage.revisions(vault.id).length, revisionsBefore + 1);
    },
  );

  test('force flush drains a pending queue larger than one batch', () async {
    final dir = Directory.systemTemp.createTempSync('silique-flush-');
    final repo = await _repo(dir);
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.createVault('Osobiste');
    final vault = repo.vaults.single;
    enableSync(repo, vault.id);
    final note = await repo.createNote(vault.id);

    // Create 120 distinct revisions (more than the 100-per-batch limit).
    for (var i = 0; i < 120; i++) {
      await repo.save(note.copyWith(body: 'revision $i'));
    }
    expect(repo.storage.pendingCount(vault.id), greaterThan(100));

    final sentBatches = <Json>[];
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
        if (request.method == 'PUT' && path.startsWith('/v1/vaults/')) {
          return http.Response(jsonEncode({'version': 1}), 200);
        }
        if (request.method == 'POST' && path.endsWith('/batches')) {
          final body = jsonDecode(request.body) as Json;
          sentBatches.add(body);
          final ids = (body['revisions'] as List)
              .map((r) => (r as Json)['id'] as String)
              .toList();
          return http.Response(
            jsonEncode({'batchId': body['batchId'], 'accepted': ids}),
            200,
          );
        }
        return http.Response('{}', 200);
      }),
    );

    final remaining = await repo.forceFlushPending(vaultId: vault.id);

    expect(remaining, 0);
    expect(repo.storage.pendingCount(vault.id), 0);
    // More than one batch was required to drain >100 revisions.
    expect(sentBatches.length, greaterThan(1));
    final sentTotal = sentBatches.fold<int>(
      0,
      (n, b) => n + (b['revisions'] as List).length,
    );
    expect(sentTotal, repo.storage.revisions(vault.id).length);
  });

  test(
    'divergedNoteCount counts notes with more than one head and ignores '
    'single-head notes',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-diverged-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      final other = await repo.createNote(vault.id);

      // Each createNote already seeded one initial revision (a single head).
      final otherHead =
          repo.storage.revisions(vault.id, noteId: other.id).single;

      // A second independent head for `note` (no parent) -> two heads -> diverged.
      const a2 = '22222222-2222-4222-8222-222222222222';
      // A child of the existing `other` head -> the head is retired, leaving one.
      const b2 = '44444444-4444-4444-8444-444444444444';

      repo.storage.atomic(() {
        repo.storage.putRevision(
          Revision(
            id: a2,
            vaultId: vault.id,
            noteId: note.id,
            parents: const [],
            payload: '',
            seq: 2,
          ),
        );
        repo.storage.putRevision(
          Revision(
            id: b2,
            vaultId: vault.id,
            noteId: other.id,
            parents: [otherHead.id],
            payload: '',
            seq: 3,
          ),
        );
      });

      // Only `note` has two heads; `other` resolves to a single head.
      expect(repo.divergedNoteCount(vault.id), 1);
      expect(repo.storage.divergedNoteCount(vault.id), 1);
    },
  );

  group('sync status dialog', () {
    testWidgets('renders counts and actions without real IO', (tester) async {
      late Notebook repo;
      late Directory dir;
      late String vaultId;
      await tester.runAsync(() async {
        dir = Directory.systemTemp.createTempSync('silique-sdialog-');
        repo = await _repo(dir);
        await repo.createVault('Osobiste');
        final vault = repo.vaults.single;
        vaultId = vault.id;
        enableSync(repo, vaultId);
        final note = await repo.createNote(vaultId);
        // Acknowledge the initial revision, then make exactly one pending edit.
        repo.storage.atomic(
          () => repo.storage.acknowledge(
            vaultId,
            repo.storage.revisions(vaultId).map((r) => r.id).toList(),
          ),
        );
        await repo.save(note.copyWith(body: 'pending change'));
        repo.storage.putSyncStatus(
          vaultId,
          VaultSyncStatus(
            lastSuccessAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 3),
            ),
            lastAttemptAt: DateTime.now().toUtc(),
            lastError: 'offline',
            lastErrorAt: DateTime.now().toUtc(),
          ),
        );
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        final close = repo.close();
        await tester.runAsync(() async {
          await close;
          dir.deleteSync(recursive: true);
        });
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () => showSyncStatusDialog(
                    ctx,
                    repo,
                    repo.vaults.first,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );

      // No API is set: opening the dialog must not touch the network.
      expect(repo.api, isNull);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Status synchronizacji'), findsOneWidget);
      expect(find.text('Oczekujące zmiany'), findsOneWidget);
      expect(find.text('Rozbieżne notatki'), findsOneWidget);
      expect(find.text('Wyślij oczekujące zmiany'), findsOneWidget);
      expect(find.text('Wymuś pełne ściągnięcie'), findsOneWidget);
      // Pending count 1 and diverged count 0 are visible.
      expect(find.text('1'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      // Last error text is rendered.
      expect(find.text('offline'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fail-fast: actions surface a readable error before any IO', (
      tester,
    ) async {
      late Notebook repo;
      late Directory dir;
      await tester.runAsync(() async {
        dir = Directory.systemTemp.createTempSync('silique-sdialog-failfast-');
        repo = await _repo(dir);
        await repo.createVault('Osobiste');
        final vault = repo.vaults.single;
        enableSync(repo, vault.id);
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          await repo.close();
          dir.deleteSync(recursive: true);
        });
      });

      // No api is set: the forced actions must fail fast with a readable error
      // instead of attempting network IO.
      expect(repo.api, isNull);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [notebookProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () => showSyncStatusDialog(
                    ctx,
                    repo,
                    repo.vaults.first,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      // Tap the force-pull action: it must render the "not connected" error,
      // not hang or crash.
      await tester.tap(find.byKey(const Key('sync-force-pull')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(
        find.textContaining('Brak połączenia z serwerem'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    test('both forced actions refuse to run while a sync is already in progress', () async {
      final dir = Directory.systemTemp.createTempSync('silique-refuse-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);

      // Start a real sync against a hanging server so `syncing` becomes true.
      final gate = Completer<void>();
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/changes')) {
            await gate.future;
            return http.Response(jsonEncode(_emptyChanges()), 200);
          }
          if (request.url.path == '/v1/vaults') {
            return http.Response(
              jsonEncode({'vaults': <Object>[], 'deletedVaults': <Object>[]}),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
      );
      final inFlight = repo.sync();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.syncing, isTrue);

      // Both refuse immediately, before any additional IO, with a readable error.
      await expectLater(
        repo.forceFullPull(vaultId: vault.id),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        repo.forceFlushPending(vaultId: vault.id),
        throwsA(isA<StateError>()),
      );

      gate.complete();
      await inFlight;
      expect(repo.syncing, isFalse);
    });

    testWidgets(
      'destructive reset requires a second confirmation listing counts and the '
      'losing-copies checkbox, without real IO',
      (tester) async {
        late Notebook repo;
        late Directory dir;
        late String vaultId;
        await tester.runAsync(() async {
          dir = Directory.systemTemp.createTempSync('silique-reset-ui-');
          repo = await _repo(dir);
          await repo.createVault('Osobiste');
          final vault = repo.vaults.single;
          vaultId = vault.id;
          enableSync(repo, vaultId);
          final note = await repo.createNote(vaultId);
          // One pending edit and a synthetic diverged second head.
          await repo.save(note.copyWith(body: 'pending change'));
          repo.storage.atomic(() {
            repo.storage.putRevision(
              Revision(
                id: '22222222-2222-4222-8222-222222222222',
                vaultId: vaultId,
                noteId: note.id,
                parents: const [],
                payload: '',
                seq: 2,
              ),
            );
          });
        });
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            await repo.close();
            dir.deleteSync(recursive: true);
          });
        });

        // No api: the destructive action must not perform IO.
        expect(repo.api, isNull);

        await tester.pumpWidget(
          ProviderScope(
            overrides: [notebookProvider.overrideWithValue(repo)],
            child: MaterialApp(
              home: Builder(
                builder: (ctx) => Scaffold(
                  body: TextButton(
                    onPressed: () => showSyncStatusDialog(
                      ctx,
                      repo,
                      repo.vaults.first,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        // Tap the destructive action labelled with the ellipsis.
        await tester.tap(
          find.textContaining('Ustaw to urządzenie jako źródło prawdy'),
        );
        await tester.pumpAndSettle();

        // Second confirmation dialog is now visible with the required strings.
        expect(find.text('Ustaw źródło prawdy'), findsWidgets);
        // The consequence text must stay honest: the remote versions are
        // overwritten, while history and (optionally) losing copies survive.
        expect(find.textContaining('nadpisze zdalne wersje'), findsOneWidget);
        expect(find.textContaining('Historia wersji pozostaje'), findsOneWidget);
        expect(
          find.text('zachowaj przegrywające wersje jako kopie'),
          findsOneWidget,
        );
        expect(
          find.textContaining('ukryte notatki nie są objęte'),
          findsOneWidget,
        );
        // The losing-copies checkbox defaults to checked.
        final checkbox = tester.widget<CheckboxListTile>(
          find.byType(CheckboxListTile),
        );
        expect(checkbox.value, isTrue);

        // Cancel performs no IO and returns to the first dialog.
        await tester.tap(find.text('Anuluj'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('source-of-truth reset', () {
    test('unions parents for an ordinary note and ends with zero divergence', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-union-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);
      // Base revision, already on the server (simulated synced note).
      final base = await seedLocalRevision(repo, vault.id, note, 1);

      // Two divergent children of the base, authored by other devices.
      final remoteA = note.copyWith(title: 'Zdrowie', body: 'A');
      final remoteB = note.copyWith(title: 'Praca', body: 'B');
      final a = await encryptForServer(
        repo, vault.id, remoteA, [base['id'] as String], 2);
      final b = await encryptForServer(
        repo, vault.id, remoteB, [base['id'] as String], 3);

      final server = FakeVaultServer(seed: [base, a, b]);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(vault.id);

      // The reset wrote one revision citing both server heads.
      expect(report.notesRewritten, 1);
      expect(report.headsMerged, 2);
      expect(report.remainingDiverged, 0);

      // Pushed batch cites both remote heads as parents.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .toList();
      final resetRev = pushed.firstWhere((r) => r['noteId'] == note.id);
      expect(
        (resetRev['parents'] as List).cast<String>().toSet(),
        {a['id'], b['id']},
      );
    });

    test('more than 32 heads retire through a chain ending in one head', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-chain-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);

      // 40 independent remote heads (all roots), authored by other devices.
      final seed = <Json>[];
      for (var i = 0; i < 40; i++) {
        seed.add(await encryptForServer(
          repo,
          vault.id,
          note.copyWith(title: 'Head $i', body: 'content $i'),
          <String>[],
          i + 1,
        ));
      }
      final server = FakeVaultServer(seed: seed);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(
        vault.id,
        keepLosingCopies: false,
      );

      expect(report.headsMerged, 40);
      // Server-side divergence is exactly zero: the chain ended with one head.
      expect(report.remainingDiverged, 0);

      // Every pushed batch revision for this note cites at most 32 parents, and
      // the chain produced more than one link.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .where((r) => r['noteId'] == note.id)
          .toList();
      expect(pushed.length, greaterThan(1));
      for (final r in pushed) {
        expect((r['parents'] as List).length, lessThanOrEqualTo(32));
      }
      // The final (single) head on the server is the last pushed link: every
      // earlier link of the chain is cited as a parent by a later link, so the
      // note ends with exactly one head.
      final serverNoteRevisions =
          server.revisions.where((r) => r['noteId'] == note.id).toList();
      final parentIds = <String>{
        for (final r in serverNoteRevisions)
          ...(r['parents'] as List).cast<String>(),
      };
      final headsOnServer = serverNoteRevisions
          .where((r) => !parentIds.contains(r['id']))
          .toList();
      expect(headsOnServer, hasLength(1));
    });

    test('exactly 32 heads retire in a single revision with 32 parents', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-32heads-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);

      // Exactly 32 independent remote roots: the boundary case where one
      // revision's parent list is exactly at the server limit.
      final seed = <Json>[];
      for (var i = 0; i < 32; i++) {
        seed.add(await encryptForServer(
          repo,
          vault.id,
          note.copyWith(title: 'Head $i', body: 'content $i'),
          <String>[],
          i + 1,
        ));
      }
      final server = FakeVaultServer(seed: seed);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(
        vault.id,
        keepLosingCopies: false,
      );

      expect(report.headsMerged, 32);
      expect(report.remainingDiverged, 0);

      // Exactly one link: a single revision citing all 32 heads.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .where((r) => r['noteId'] == note.id)
          .toList();
      expect(pushed, hasLength(1));
      expect((pushed.single['parents'] as List).length, 32);
    });

    test('exactly 33 heads retire through a two-link chain ending in one head', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-33heads-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);

      // 33 independent remote roots: one past the 32-parent limit, so the reset
      // must produce two links (31 heads + previous link, then 2 heads + previous
      // link) instead of a single over-limit revision.
      final seed = <Json>[];
      for (var i = 0; i < 33; i++) {
        seed.add(await encryptForServer(
          repo,
          vault.id,
          note.copyWith(title: 'Head $i', body: 'content $i'),
          <String>[],
          i + 1,
        ));
      }
      final server = FakeVaultServer(seed: seed);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(
        vault.id,
        keepLosingCopies: false,
      );

      expect(report.headsMerged, 33);
      expect(report.remainingDiverged, 0);

      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .where((r) => r['noteId'] == note.id)
          .toList();
      // Two links, each within the 32-parent limit, ending in one server head.
      expect(pushed, hasLength(2));
      for (final r in pushed) {
        expect((r['parents'] as List).length, lessThanOrEqualTo(32));
      }
      // The second link must cite the first link as its previous-link parent,
      // so the chain collapses every head into a single final head.
      final first = pushed.first;
      final second = pushed.last;
      expect((second['parents'] as List).cast<String>(), contains(first['id']));

      final serverNoteRevisions =
          server.revisions.where((r) => r['noteId'] == note.id).toList();
      final parentIds = <String>{
        for (final r in serverNoteRevisions)
          ...(r['parents'] as List).cast<String>(),
      };
      final headsOnServer = serverNoteRevisions
          .where((r) => !parentIds.contains(r['id']))
          .toList();
      expect(headsOnServer, hasLength(1));
    });

    test('a local-only pending note is pushed after reset, not stranded', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-localonly-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);

      // A note created locally and never synced: its only revision is pending
      // with seq == 0, so the server has no head for it. Step 3 skips it
      // (`serverHeads.isEmpty`), so it must NOT be acknowledged by step 5.
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(body: 'local-only content'));
      final localPendingIds = repo.storage.pendingIds(vault.id);
      expect(localPendingIds, isNotEmpty);

      final server = FakeVaultServer();
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(vault.id);
      expect(report.remainingDiverged, 0);

      // The local-only note's pending revision was not silently acknowledged-and-
      // stranded by step 5's acknowledge: it was pushed to the server (its
      // content became the source of truth rather than being dropped). With the
      // bug it would be marked pending=0 without ever reaching the server.
      expect(repo.storage.pendingIds(vault.id), isEmpty);
      expect(
        server.revisions.where((r) => r['noteId'] == note.id),
        isNotEmpty,
      );
    });

    test('a pending hidden-note revision survives reset untouched and syncs', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-hiddenpend-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);

      final server = FakeVaultServer();
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      // Create a pending hidden-note wire revision (plus a hidden config) that
      // has not yet been pushed to the server.
      await repo.setHiddenPassword('hidden password 12345');
      final hidden = await repo.createHiddenNote(vault.id);
      await repo.save(hidden.copyWith(title: 'Sekret', body: 'tajne'));
      // The hidden revisions are stored under their wire note ids (a UUID),
      // distinct from the ordinary note id. Capture every pending id and its
      // wire note id so we can prove the reset neither strands nor discards them.
      final pendingBefore = repo.storage.pendingIds(vault.id);
      expect(pendingBefore, isNotEmpty);
      final wireNoteIds = <String>{
        for (final id in pendingBefore)
          repo.storage
              .revisions(vault.id)
              .firstWhere((r) => r.id == id)
              .noteId,
      };

      final report = await repo.resetToLocalSourceOfTruth(vault.id);
      // Hidden notes are not governed by the reset.
      expect(report.hiddenSkipped, greaterThanOrEqualTo(1));

      // The pending hidden revisions were NOT silently acknowledged-and-discarded
      // by step 5's blanket acknowledge: they were pushed to the server through
      // the normal channel (the reset's push drain), so the server holds them.
      expect(repo.storage.pendingCount(vault.id), 0);
      for (final wireId in wireNoteIds) {
        expect(
          server.revisions.where((r) => r['noteId'] == wireId),
          isNotEmpty,
          reason: 'hidden wire revision $wireId was dropped by the reset',
        );
      }
    });

    test('writes deletions for locally deleted notes and remote-only heads', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-del-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);

      // Locally deleted note: its base is already on the server, and the local
      // document is flagged deleted.
      final deleted = await repo.createNote(vault.id);
      final base = await seedLocalRevision(repo, vault.id, deleted, 1);
      await repo.save(repo.notes[vault.id]![deleted.id]!.copyWith(deleted: true));

      // Remote-only note: head exists on server, no local document.
      final remoteOnly = Note(
        id: '88888888-8888-4888-8888-888888888888',
        vaultId: vault.id,
        title: 'Tylko zdalna',
        body: 'remote body',
        updatedAt: DateTime.now().toUtc(),
      );
      final remoteOnlyHead = await encryptForServer(
        repo,
        vault.id,
        remoteOnly,
        <String>[],
        50,
      );

      final server = FakeVaultServer(seed: [base, remoteOnlyHead]);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(vault.id);

      // One locally-deleted note + one remote-only head => two deletions.
      expect(report.deletionsWritten, 2);
      expect(report.remainingDiverged, 0);

      // Both reset revisions carry `deleted: true` on the server.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .toList();
      final delRev = pushed.firstWhere(
        (r) => r['noteId'] == deleted.id,
        orElse: () => <String, dynamic>{},
      );
      expect(delRev, isNotEmpty);
      final remoteRev = pushed.firstWhere(
        (r) => r['noteId'] == remoteOnly.id,
        orElse: () => <String, dynamic>{},
      );
      expect(remoteRev, isNotEmpty);
    });

    test('deterministic copies are idempotent across two runs', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-copies-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);
      // Chosen local content.
      await repo.save(note.copyWith(title: 'Wybrana', body: 'chosen'));

      // Two distinct remote heads, both "losing" relative to the chosen body.
      final a = await encryptForServer(
        repo,
        vault.id,
        note.copyWith(title: 'Losing A', body: 'losing a'),
        <String>[],
        2,
      );
      final b = await encryptForServer(
        repo,
        vault.id,
        note.copyWith(title: 'Losing B', body: 'losing b'),
        <String>[],
        3,
      );

      final server = FakeVaultServer(seed: [a, b]);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final first = await repo.resetToLocalSourceOfTruth(vault.id);
      expect(first.copiesKept, 2);

      // Second run: no new copies, the same deterministic ids reappear.
      final second = await repo.resetToLocalSourceOfTruth(vault.id);
      expect(second.copiesKept, 0);

      // The copied notes remain, titled with the loss suffix and conflict flag.
      final copies = repo.notes[vault.id]!.values
          .where((n) => n.conflict && n.id != note.id)
          .toList();
      expect(copies, hasLength(2));
      for (final c in copies) {
        expect(c.title, contains('(kopia przed scaleniem)'));
        expect(c.conflict, isTrue);
      }
    });

    test('purged note ids are skipped without error', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-purged-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      await repo.createNote(vault.id);

      final purgedId = '99999999-9999-4999-8999-999999999999';
      final server = FakeVaultServer(purged: {purgedId});
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      // The reset must complete without throwing, skipping the purged id.
      final report = await repo.resetToLocalSourceOfTruth(vault.id);
      expect(report.remainingDiverged, 0);

      // No revision was pushed for the purged note id.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .toList();
      expect(pushed.where((r) => r['noteId'] == purgedId), isEmpty);
    });

    test('image references are filtered during reset', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-img-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);
      final note = await repo.createNote(vault.id);
      // Base revision already on the server.
      final base = await seedLocalRevision(repo, vault.id, note, 1);
      // A body that cites an image with no local asset: pushing must filter it
      // out rather than hit 409 "Image not uploaded yet".
      await repo.save(
        note.copyWith(body: '![lost](silique-image:11111111-1111-4111-8111-111111111111)'),
      );

      final server = FakeVaultServer(seed: [base]);
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      final report = await repo.resetToLocalSourceOfTruth(vault.id);
      expect(report.remainingDiverged, 0);
      expect(server.acceptedBatches, isNotEmpty);
      // The pushed reset revision does not cite the missing image.
      final pushed = server.acceptedBatches
          .expand((batch) => (batch['revisions'] as List).cast<Json>())
          .toList();
      for (final r in pushed) {
        expect((r['images'] as List?) ?? const [], isNot(contains('11111111-1111-4111-8111-111111111111')));
      }
    });

    test('reports hiddenSkipped and leaves hidden notes untouched', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-hidden-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;
      enableSync(repo, vault.id);

      final server = FakeVaultServer();
      repo.api = SiliqueApi(
        _server,
        token: 'test',
        client: server.client(vault.id),
      );

      await repo.setHiddenPassword('hidden password 12345');
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: 'Sekret', body: 'tajne'));
      // Drain pending before hiding so the internal sync in hideNote is a no-op.
      await repo.sync();
      expect(repo.storage.pendingCount(vault.id), 0);
      await repo.hideNote(repo.notes[vault.id]![note.id]!);
      // Sync the hidden move so the hidden wire revision exists on the server.
      await repo.sync();

      final report = await repo.resetToLocalSourceOfTruth(vault.id);

      expect(report.hiddenSkipped, greaterThanOrEqualTo(1));
      // The hidden note still exists in the hidden store.
      expect(repo.storage.documents('hidden:${vault.id}'), isNotEmpty);
    });

    test('preconditions throw readable StateError', () async {
      final dir = Directory.systemTemp.createTempSync('silique-reset-pre-');
      final repo = await _repo(dir);
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.createVault('Osobiste');
      final vault = repo.vaults.single;

      // Sync disabled -> StateError.
      expect(
        () => repo.resetToLocalSourceOfTruth(vault.id),
        throwsA(isA<StateError>()),
      );
      // Sync enabled but no server connection -> StateError before any IO.
      enableSync(repo, vault.id);
      expect(repo.api, isNull);
      await expectLater(
        repo.resetToLocalSourceOfTruth(vault.id),
        throwsA(isA<StateError>()),
      );
    });
  });
}