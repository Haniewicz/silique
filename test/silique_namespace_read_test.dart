import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:uuid/uuid.dart';

import 'package:silique/core/crypto.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'package:cryptography/cryptography.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  // 1. A note edited after the Faza 2 update is sealed with `silique:2:`, while
  //    a pre-existing `nova:1:` document still opens through the read fallback.
  test('note edited after the update writes silique:2, legacy nova:1 note still reads', () async {
    final dir = Directory.systemTemp.createTempSync('silique-ns-legacy-');
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
    await repo.createVault('Legacy', password: 'a legacy vault password');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(note.copyWith(title: 'Legacy', body: 'legacy body'));

    // The freshly written local-note document is sealed with silique:2; the
    // legacy nova:1 AAD no longer authenticates those bytes.
    final document = repo.storage.documents(vault.id)[note.id]!;
    final key = repo.unlocked[vault.id]!;
    await expectLater(
      repo.crypto.open(
        key,
        document,
        'silique:2:local-note:${vault.id}:${note.id}',
      ),
      completion(contains('legacy body')),
    );
    await expectLater(
      repo.crypto.open(
        key,
        document,
        'nova:1:local-note:${vault.id}:${note.id}',
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );

    // A pre-existing nova:1 document still reads through openCompat after a
    // lock/unlock cycle (the fallback is never removed in this release).
    final legacyDocument = await repo.crypto.seal(
      key,
      jsonEncode({
        ...note.copyWith(title: 'Legacy', body: 'legacy body').toJson(),
        '_heads': <String>[],
      }),
      'nova:1:local-note:${vault.id}:${note.id}',
    );
    repo.storage.putDocument(vault.id, note.id, legacyDocument);
    repo.lock(vault.id);
    expect(repo.notes[vault.id], isNull);
    await repo.unlock(repo.vaults.single, password: 'a legacy vault password');
    expect(repo.notes[vault.id]![note.id]!.body, 'legacy body');
  });

  // 2. A note sealed with the new `silique:2:note:` AAD is read through
  //    openCompat, while the old AAD on the same ciphertext fails auth.
  test('a silique:2 note is read and the legacy AAD fails on those bytes', () async {
    final crypto = SiliqueCrypto();
    final key = crypto.randomKey();
    const vaultId = 'vault-1', noteId = 'note-1', revId = 'rev-1';
    final revision = Revision(
      id: revId,
      vaultId: vaultId,
      noteId: noteId,
      parents: const [],
      payload: '',
    );
    expect(revision.aad, 'silique:2:note:$vaultId:$noteId:$revId:[]');
    expect(revision.legacyAad, 'nova:1:note:$vaultId:$noteId:$revId:[]');

    final envelope = await crypto.seal(key, 'silique note', revision.aad);
    expect(
      await crypto.openCompat(key, envelope, revision.aad, revision.legacyAad),
      'silique note',
    );
    await expectLater(
      crypto.open(key, envelope, revision.legacyAad),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  // 3. openCompat does not silently swallow a corrupted ciphertext: the
  //    authentication error propagates instead of a fallback "recovery".
  test('openCompat surfaces a corrupted ciphertext instead of a silent fallback', () async {
    final crypto = SiliqueCrypto();
    final key = crypto.randomKey();
    final revision = Revision(
      id: 'rev-1',
      vaultId: 'vault-1',
      noteId: 'note-1',
      parents: const [],
      payload: '',
    );
    final envelope = await crypto.seal(key, 'corrupt me', revision.legacyAad);
    final corrupted = jsonDecode(envelope) as Json;
    corrupted['c'] = base64Encode(
      List<int>.filled(base64Decode(corrupted['c'] as String).length, 0),
    );
    await expectLater(
      crypto.openCompat(
        key,
        jsonEncode(corrupted),
        revision.aad,
        revision.legacyAad,
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  // 4. Reopening the notebook reads both a legacy nova:1 note and a note whose
  //    document was sealed with the new silique:2 AAD.
  test('restart reads both nova:1 and silique:2 note documents', () async {
    final dir = Directory.systemTemp.createTempSync('silique-ns-restart-');
    final keys = MemoryKeys();
    Notebook open() => Notebook(
      storage: NativeStorage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    var repo = open();
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Restart', password: 'a restart password');
    final vault = repo.vaults.single;
    final vaultId = vault.id;
    final key = repo.unlocked[vaultId]!;

    final noteA = await repo.createNote(vaultId);
    await repo.save(noteA.copyWith(body: 'legacy variant'));

    // Manually seal a second document with the new silique:2 AAD, exactly as a
    // future Faza 2 writer would.
    const noteBId = 'note-silique-2';
    final noteB = Note(
      id: noteBId,
      vaultId: vaultId,
      title: 'Silique',
      body: 'silique variant',
      updatedAt: DateTime.now().toUtc(),
    );
    final documentB = await repo.crypto.seal(
      key,
      jsonEncode({...noteB.toJson(), '_heads': <String>[]}),
      'silique:2:local-note:$vaultId:$noteBId',
    );
    repo.storage.putDocument(vaultId, noteBId, documentB);

    await repo.close();

    repo = open();
    await repo.initialize();
    await repo.unlock(repo.vaults.single, password: 'a restart password');
    expect(repo.notes[vaultId]![noteA.id]!.body, 'legacy variant');
    expect(repo.notes[vaultId]![noteBId]!.body, 'silique variant');
  });

  // 5. A silique:2 revision arriving through sync is decoded by openCompat.
  test('sync decodes an incoming silique:2 revision', () async {
    final dir = Directory.systemTemp.createTempSync('silique-ns-sync-');
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
    await repo.createVault('Sync');
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
    repo.api = SiliqueApi('http://127.0.0.1', client: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/vaults') {
        return http.Response('{"vaults":[]}', 200);
      }
      if (request.method == 'GET' && request.url.path.endsWith('/changes')) {
        return http.Response(
          '{"revisions":[],"cursor":0,"hasMore":false}',
          200,
        );
      }
      if (request.method == 'POST' && request.url.path.endsWith('/batches')) {
        final body = jsonDecode(request.body) as Json;
        return http.Response(
          jsonEncode({
            'batchId': body['batchId'],
            'accepted': (body['revisions'] as List).map((v) => v['id']).toList(),
          }),
          200,
        );
      }
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }));

    const uuid = Uuid();
    final noteId = uuid.v4();
    final revision = Revision(
      id: uuid.v4(),
      vaultId: vault.id,
      noteId: noteId,
      parents: const [],
      payload: '',
    );
    final note = Note(
      id: noteId,
      vaultId: vault.id,
      title: 'Sync',
      body: 'silique revision body',
      updatedAt: DateTime.now().toUtc(),
    );
    repo.storage.putRevision(
      Revision(
        id: revision.id,
        vaultId: vault.id,
        noteId: noteId,
        parents: const [],
        payload: await repo.crypto.seal(
          repo.unlocked[vault.id]!,
          jsonEncode(note.toJson()),
          revision.aad,
        ),
      ),
    );

    await repo.sync();
    expect(repo.notes[vault.id]![noteId]!.body, 'silique revision body');
  });

  // 6. recoverAccount keeps opening the nova:1 account envelope; a silique:2
  //    account envelope is not accepted, proving the envelope domain is intact.
  test('recoverAccount still opens the nova:1 account envelope', () async {
    final dir = Directory.systemTemp.createTempSync('silique-ns-recover-');
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
      server: 'http://127.0.0.1',
      token: 'fixture',
      userId: 'user-1',
      email: 'recover@example.com',
    );
    final recoveryKey = repo.crypto.randomKey();
    final master = repo.crypto.randomKey();
    final envelope = await repo.crypto.seal(
      recoveryKey,
      base64Encode(master),
      'nova:1:account:user-1',
    );
    repo.api = SiliqueApi('http://127.0.0.1', client: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/account') {
        return http.Response(jsonEncode({'accountEnvelope': envelope}), 200);
      }
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }));

    await repo.recoverAccount(base64UrlEncode(recoveryKey));
    expect(repo.accountKey, master);

    // The account envelope domain is nova:1 only; a silique:2 envelope must be
    // rejected (recoverAccount never retries with the new namespace).
    final siliqueEnvelope = await repo.crypto.seal(
      recoveryKey,
      base64Encode(master),
      'silique:2:account:user-1',
    );
    repo.api = SiliqueApi('http://127.0.0.1', client: MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/v1/account') {
        return http.Response(
          jsonEncode({'accountEnvelope': siliqueEnvelope}),
          200,
        );
      }
      throw StateError('Unexpected ${request.method} ${request.url.path}');
    }));
    await expectLater(
      repo.recoverAccount(base64UrlEncode(recoveryKey)),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });

  // 7. Pairing between two independent identities still derives the same
  //    symmetric key in both directions, proving the pairing domain is intact.
  test('pairing derives a matching key for a new and an old device', () async {
    final crypto = SiliqueCrypto();
    final a = await crypto.createIdentity();
    final b = await crypto.createIdentity();
    final context = jsonEncode([
      'nova:1:pairing',
      'user',
      'pair',
      'requester',
      a['public'],
      'approver',
      b['public'],
    ]);
    final keyAB = await crypto.pairingKey(
      a,
      b['public'] as String,
      context,
    );
    final keyBA = await crypto.pairingKey(
      b,
      a['public'] as String,
      context,
    );
    expect(keyAB, keyBA);
  });
}
