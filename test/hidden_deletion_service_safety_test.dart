import 'dart:async';
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

class DelayedIndexCrypto extends TestCrypto {
  Completer<void>? indexEntered;
  Completer<void>? releaseIndex;

  @override
  Future<String> open(List<int> key, String envelope, String context) async {
    if (context.startsWith('silique:1:hidden-index:') && releaseIndex != null) {
      final gate = releaseIndex!;
      releaseIndex = null;
      indexEntered!.complete();
      await gate.future;
    }
    return super.open(key, envelope, context);
  }
}

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  late Directory dir;
  late Notebook repo;
  late DelayedIndexCrypto crypto;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hidden-delete-service-');
    crypto = DelayedIndexCrypto();
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: crypto,
    );
    await repo.initialize();
    await repo.createVault('Safety');
    await repo.setHiddenPassword('extra password');
  });
  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });

  test('permanent deletion of a live local hidden note keeps its retired ordinary identity', () async {
    final vault = repo.vaults.single;
    final ordinary = await repo.createNote(vault.id);
    await repo.hideNote(ordinary);
    expect(repo.storage.documents('hidden:${vault.id}'), contains(ordinary.id));
    await repo.deleteHiddenNote(vault.id, ordinary.id);
    expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
    expect(repo.storage.documents('hidden-sync:${vault.id}'), isEmpty);
    expect(
      repo.storage.documents('hidden-retired:${vault.id}'),
      contains(ordinary.id),
    );
    expect(await repo.hiddenNotes(vault.id), isEmpty);
    await expectLater(
      repo.save(ordinary.copyWith(body: 'stale')),
      throwsStateError,
    );
  });

  test('deletion rejects a locked session and preserves ciphertext', () async {
    final note = await repo.createHiddenNote(repo.vaults.single.id);
    final before = repo.storage.documents('hidden:${note.vaultId}')[note.id];
    await repo.lockHidden();
    await expectLater(
      repo.deleteHiddenNote(note.vaultId, note.id),
      throwsStateError,
    );
    expect(repo.storage.documents('hidden:${note.vaultId}')[note.id], before);
  });

  test('unhide targets a validated folder or root without modifying ciphertext on invalid path', () async {
    final vault = repo.vaults.single;
    final note = await repo.createHiddenNote(vault.id);
    await repo.save(note.copyWith(folder: 'Original', body: 'secret'));
    await expectLater(
      repo.unhideNote(vault.id, note.id, folder: 'Bad//Folder'),
      throwsFormatException,
    );
    expect(repo.storage.documents('hidden:${vault.id}'), contains(note.id));
    final restored = await repo.unhideNote(
      vault.id,
      note.id,
      folder: 'Target/Nested',
    );
    expect(restored.folder, 'Target/Nested');
    expect(restored.body, 'secret');
    expect(repo.notes[vault.id]![restored.id]!.folder, 'Target/Nested');
    final second = await repo.createHiddenNote(vault.id);
    await repo.save(second.copyWith(folder: 'Original'));
    expect((await repo.unhideNote(vault.id, second.id, folder: '')).folder, '');
  });

  test(
    'offline synced deletion preserves ciphertext, index and pending outbox',
    () async {
      final vault = repo.vaults.single;
      vault.owner = 'http://127.0.0.1|owner';
      vault.syncEnabled = true;
      repo.storage.putVault(vault);
      repo.accountKey = repo.localKey;
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'test',
        userId: 'owner',
        email: 'test@example.com',
      );
      repo.api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient(
          (_) async => http.Response('{"error":"offline"}', 503),
        ),
      );
      final note = await repo.createHiddenNote(vault.id);
      await repo.save(note.copyWith(body: 'offline secret'));
      final beforePending = repo.storage.pending(vault.id);
      expect(beforePending, isNotEmpty);
      final sealed = repo.storage.documents('hidden:${vault.id}')[note.id];
      final index = repo.storage.documents('hidden-sync:${vault.id}')[note.id];
      await expectLater(
        repo.deleteHiddenNote(vault.id, note.id),
        throwsA(isA<ApiException>()),
      );
      expect(repo.storage.documents('hidden:${vault.id}')[note.id], sealed);
      expect(repo.storage.documents('hidden-sync:${vault.id}')[note.id], index);
      expect(
        repo.storage.pending(vault.id).map((r) => r.id),
        orderedEquals(beforePending.map((r) => r.id)),
      );
      expect((await repo.hiddenNotes(vault.id)).single.body, 'offline secret');
    },
  );

  test('synced deletion retires opaque wire remotely and cannot replay pending revisions', () async {
    final vault = repo.vaults.single;
    final note = await repo.createHiddenNote(vault.id);
    await repo.save(note.copyWith(body: 'SYNC_SECRET'));
    vault.owner = 'http://127.0.0.1|owner';
    vault.syncEnabled = true;
    repo.storage.putVault(vault);
    repo.accountKey = repo.localKey;
    repo.session = Session(
      server: 'http://127.0.0.1',
      token: 'test',
      userId: 'owner',
      email: 'test@example.com',
    );
    final uploaded = <String>{};
    final deleted = <String>[];
    var remotePurges = false;
    var refuseDelete = true;
    repo.api = SiliqueApi(
      'http://127.0.0.1',
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'GET' && path == '/v1/vaults') {
          return http.Response(
            jsonEncode({
              'vaults': [
                {
                  'id': vault.id,
                  'keyWrap': vault.keyWrap,
                  'metadata': vault.metadata,
                  'version': vault.version,
                },
              ],
            }),
            200,
          );
        }
        if (request.method == 'GET' && path.endsWith('/changes')) {
          return http.Response(
            jsonEncode({
              'purged': remotePurges ? deleted : [],
              'revisions': [],
              'cursor': 0,
              'hasMore': false,
            }),
            200,
          );
        }
        if (request.method == 'POST' && path.endsWith('/batches')) {
          final batch = jsonDecode(request.body) as Map<String, dynamic>;
          final ids = (batch['revisions'] as List)
              .map((r) => (r as Map<String, dynamic>)['id'] as String)
              .toList();
          uploaded.addAll(ids);
          return http.Response(
            jsonEncode({'batchId': batch['batchId'], 'accepted': ids}),
            200,
          );
        }
        if (request.method == 'DELETE' && path.contains('/notes/')) {
          if (refuseDelete) return http.Response('{"error":"refused"}', 503);
          deleted.add(path.split('/').last);
          return http.Response('{"purged":true}', 200);
        }
        return http.Response('{}', 404);
      }),
    );
    // Simulate a remote-imported, already-synced envelope: unlike a local
    // ordinary-to-hidden move it has no local retirement marker.
    await repo.sync();
    repo.storage.removeDocument('hidden-retired:${vault.id}', note.id);
    // A failed server retirement must leave local ciphertext and routing intact.
    await expectLater(
      repo.deleteHiddenNote(vault.id, note.id),
      throwsA(isA<ApiException>()),
    );
    expect(repo.storage.documents('hidden:${vault.id}'), contains(note.id));
    final index = repo.storage.documents('hidden-sync:${vault.id}');
    expect(index, contains(note.id));
    refuseDelete = false;
    crypto.indexEntered = Completer<void>();
    crypto.releaseIndex = Completer<void>();
    final interrupted = repo.deleteHiddenNote(vault.id, note.id);
    final entered = crypto.indexEntered!;
    final release = crypto.releaseIndex!;
    await entered.future;
    final locking = repo.lockHidden();
    release.complete();
    await expectLater(interrupted, throwsStateError);
    await locking;
    expect(
      deleted,
      isEmpty,
      reason: 'No DELETE after the hidden key was revoked',
    );
    expect(repo.storage.documents('hidden:${vault.id}'), contains(note.id));
    expect(await repo.unlockHidden('extra password'), isTrue);
    await repo.deleteHiddenNote(vault.id, note.id);
    expect(deleted, hasLength(1));
    expect(
      deleted.single,
      isNot(note.id),
      reason: 'The remote ID must be opaque',
    );
    expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
    expect(repo.storage.documents('hidden-sync:${vault.id}'), isEmpty);
    expect(
      repo.storage.documents('hidden-retired:${vault.id}'),
      contains(note.id),
    );
    expect(repo.storage.revisions(vault.id, noteId: deleted.single), isEmpty);
    expect(repo.storage.pending(vault.id), isEmpty);
    remotePurges = true;
    await repo.sync();
    expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
    expect(repo.storage.pending(vault.id), isEmpty);
    expect(deleted, hasLength(1));
    expect(uploaded, isNotEmpty);
  });

  test(
    'real server tombstone removes stale hidden edits on another device',
    () async {
      final remoteDir = Directory.systemTemp.createTempSync(
        'hidden-delete-peer-',
      );
      final peer = Notebook(
        storage: NativeStorage(remoteDir.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      try {
        await peer.initialize();
        final recovery = await repo.connect(
          server!,
          'hidden-delete-${DateTime.now().microsecondsSinceEpoch}@example.com',
          'disposable account password',
          register: true,
        );
        final vault = repo.vaults.single;
        await repo.enableSync(vault);
        final note = await repo.createHiddenNote(vault.id);
        await repo.save(note.copyWith(body: 'remote original'));
        await repo.sync();
        await peer.connect(
          server,
          repo.session!.email,
          'disposable account password',
          recoveryKey: recovery,
        );
        await peer.sync();
        expect(await peer.unlockHidden('extra password'), isTrue);
        final old = (await peer.hiddenNotes(vault.id)).single;
        await repo.deleteHiddenNote(vault.id, note.id);
        await peer.save(old.copyWith(body: 'stale peer edit'));
        await peer.sync();
        expect(await peer.hiddenNotes(vault.id), isEmpty);
        expect(peer.storage.documents('hidden:${vault.id}'), isEmpty);
        expect(peer.storage.pending(vault.id), isEmpty);
        await repo.sync();
        expect(await repo.hiddenNotes(vault.id), isEmpty);
        expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
      } finally {
        await peer.close();
        remoteDir.deleteSync(recursive: true);
      }
    },
    skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false,
  );
}
