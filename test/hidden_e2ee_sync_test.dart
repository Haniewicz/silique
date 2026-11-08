import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:silique/services/api.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'sync_integration_test.dart' show LostAcknowledgement;

void main() {
  final server = Platform.environment['SILIQUE_TEST_SERVER'];
  test('hidden outbox retries byte-identically after committed batch acknowledgement loss and restart', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-ack-'),
    );
    final keys = [MemoryKeys(), MemoryKeys()];
    Notebook make(int i) => Notebook(
      storage: NativeStorage(dirs[i].path),
      keys: keys[i],
      crypto: TestCrypto(),
    );
    final clients = [make(0), make(1)];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    var a = clients[0];
    final b = clients[1];
    await a.initialize();
    await b.initialize();
    final recovery = await a.connect(
      server!,
      'hidden-ack-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'disposable account password',
      register: true,
    );
    await a.createVault('ACK');
    final v = a.vaults.single;
    await a.enableSync(v);
    await a.setHiddenPassword('portable extra password');
    final note = await a.createHiddenNote(v.id);
    await a.save(note.copyWith(body: 'SECRET_ACK_CONTENT'));
    await a.lockHidden();
    a.api!.close();
    a.api = SiliqueApi(
      server,
      token: a.session!.token,
      client: LostAcknowledgement(),
    );
    await expectLater(a.sync(), throwsA(isA<http.ClientException>()));
    final batch = jsonEncode(a.storage.batch(v.id));
    expect(batch, isNot('null'));
    expect(batch, isNot(contains('SECRET_ACK_CONTENT')));
    await a.close();
    a = make(0);
    clients[0] = a;
    await a.initialize();
    expect(a.hiddenUnlocked, isFalse);
    expect(jsonEncode(a.storage.batch(v.id)), batch);
    await a.sync();
    expect(a.storage.batch(v.id), isNull);
    expect(a.storage.pending(v.id), isEmpty);
    await b.connect(
      server,
      a.session!.email,
      'disposable account password',
      recoveryKey: recovery,
    );
    await b.sync();
    expect(await b.unlockHidden('portable extra password'), isTrue);
    expect((await b.hiddenNotes(v.id)).single.body, 'SECRET_ACK_CONTENT');
    expect(b.notes[v.id], isEmpty);
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);

  test('independent local passwords remain separate and imported notes keep their key domain', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-domains-'),
    );
    final clients = [
      for (final d in dirs)
        Notebook(
          storage: NativeStorage(d.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients[0], b = clients[1];
    await a.initialize();
    await b.initialize();
    await b.createVault('B local');
    final localVault = b.vaults.single;
    await b.setHiddenPassword('B independent password');
    final localNote = await b.createHiddenNote(localVault.id);
    await b.save(localNote.copyWith(body: 'B_LOCAL_SECRET'));
    await b.lockHidden();
    final recovery = await a.connect(
      server!,
      'hidden-domains-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'disposable account password',
      register: true,
    );
    await a.createVault('A remote');
    final v = a.vaults.single;
    await a.enableSync(v);
    await a.setHiddenPassword('A portable password');
    final note = await a.createHiddenNote(v.id);
    await a.save(note.copyWith(body: 'A_REMOTE_SECRET'));
    await a.sync();
    await b.connect(
      server,
      a.session!.email,
      'disposable account password',
      recoveryKey: recovery,
    );
    await b.sync();
    expect(await b.unlockHidden('A portable password'), isTrue);
    expect((await b.hiddenNotes(v.id)).single.body, 'A_REMOTE_SECRET');
    expect(
      await b.hiddenNotes(localVault.id),
      isEmpty,
      reason:
          'Import must not overwrite or unlock an independent local password',
    );
    await b.save(
      (await b.hiddenNotes(v.id)).single.copyWith(body: 'B_EDITED_A_DOMAIN'),
    );
    final created = await b.createHiddenNote(v.id);
    await b.save(created.copyWith(body: 'B_NEW_A_DOMAIN'));
    final ordinary = await b.createNote(v.id);
    await b.save(ordinary.copyWith(body: 'B_MOVED_A_DOMAIN'));
    await b.hideNote(b.notes[v.id]![ordinary.id]!);
    await b.sync();
    await a.sync();
    expect(
      (await a.hiddenNotes(v.id)).map((n) => n.body),
      containsAll(['B_EDITED_A_DOMAIN', 'B_NEW_A_DOMAIN', 'B_MOVED_A_DOMAIN']),
    );
    await b.lockHidden();
    expect(await b.unlockHidden('B independent password'), isTrue);
    expect((await b.hiddenNotes(localVault.id)).single.body, 'B_LOCAL_SECRET');
    expect(await b.hiddenNotes(v.id), isEmpty);
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);

  test('legacy local ciphertext migrates once and unhide retires it on both clients', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-migrate-'),
    );
    final keys = [MemoryKeys(), MemoryKeys()];
    final clients = [
      for (var i = 0; i < 2; i++)
        Notebook(
          storage: NativeStorage(dirs[i].path),
          keys: keys[i],
          crypto: TestCrypto(),
        ),
    ];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients[0], b = clients[1];
    await a.initialize();
    await b.initialize();
    await a.createVault('Legacy');
    final v = a.vaults.single;
    await a.setHiddenPassword('legacy extra password');
    final note = await a.createNote(v.id);
    await a.save(note.copyWith(body: 'LEGACY_PRIVATE'));
    await a.hideNote(a.notes[v.id]![note.id]!);
    // Reconstruct the pre-sync release: ciphertext + legacy keystore slots,
    // without the new routing index or any hidden revisions.
    a.storage.removeDocument('hidden-sync:${v.id}', note.id);
    final ciphertext = a.storage.documents('hidden:${v.id}')[note.id];
    expect(
      a.storage.revisions(v.id),
      isEmpty,
      reason: 'This is the old local-only format',
    );
    await a.lockHidden();
    final recovery = await a.connect(
      server!,
      'hidden-migration-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'disposable account password',
      register: true,
    );
    await a.enableSync(v);
    await a.sync();
    expect(
      a.storage.documents('hidden:${v.id}')[note.id],
      ciphertext,
      reason: 'Migration must preserve the existing encrypted recovery copy',
    );
    final count = a.storage.revisions(v.id).length;
    await a.sync();
    expect(a.storage.revisions(v.id), hasLength(count));
    await b.connect(
      server,
      a.session!.email,
      'disposable account password',
      recoveryKey: recovery,
    );
    await b.sync();
    expect(await b.unlockHidden('legacy extra password'), isTrue);
    final hidden = (await b.hiddenNotes(v.id)).single;
    expect(hidden.body, 'LEGACY_PRIVATE');
    final restored = await b.unhideNote(v.id, hidden.id);
    await b.sync();
    await a.sync();
    expect(await a.unlockHidden('legacy extra password'), isTrue);
    for (final c in clients) {
      expect(
        await c.hiddenNotes(v.id),
        isEmpty,
        reason: 'Unhide must not be resurrected by encrypted history',
      );
      expect(c.storage.documents('hidden:${v.id}'), isEmpty);
      expect(c.notes[v.id]![restored.id]!.body, 'LEGACY_PRIVATE');
    }
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);

  test('hidden concurrent edits retain encrypted conflict alternatives and converge', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-conflict-'),
    );
    final clients = [
      for (final d in dirs)
        Notebook(
          storage: NativeStorage(d.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients[0], b = clients[1];
    await a.initialize();
    await b.initialize();
    final recovery = await a.connect(
      server!,
      'hidden-conflict-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'disposable account password',
      register: true,
    );
    await a.createVault('Conflict');
    final v = a.vaults.single;
    await a.enableSync(v);
    await a.setHiddenPassword('extra password shared');
    final note = await a.createHiddenNote(v.id);
    await a.save(note.copyWith(body: 'base'));
    await a.sync();
    await b.connect(
      server,
      a.session!.email,
      'disposable account password',
      recoveryKey: recovery,
    );
    await b.sync();
    expect(await b.unlockHidden('extra password shared'), isTrue);
    await a.save(
      (await a.hiddenNotes(v.id)).single.copyWith(body: 'LEFT_SECRET'),
    );
    await b.save(
      (await b.hiddenNotes(v.id)).single.copyWith(body: 'RIGHT_SECRET'),
    );
    await a.lockHidden();
    await b.lockHidden();
    await a.sync();
    await b.sync();
    await a.sync();
    expect(await a.unlockHidden('extra password shared'), isTrue);
    expect(await b.unlockHidden('extra password shared'), isTrue);
    // A queued editor save captured before the locked pull must not acknowledge
    // the unseen competing head merely because it is now in the local DAG.
    await b.save(note.copyWith(body: 'RIGHT_SECRET_EDIT'));
    await b.sync();
    await a.sync();
    for (final c in clients) {
      final notes = await c.hiddenNotes(v.id);
      expect(
        notes.map((n) => n.body).toSet(),
        containsAll(['LEFT_SECRET', 'RIGHT_SECRET_EDIT']),
      );
      expect(
        notes.every((n) => n.hidden && n.createdAt == note.createdAt),
        isTrue,
      );
      expect(c.notes[v.id], isEmpty);
    }
    await a.sync();
    await b.sync();
    await a.sync();
    await b.sync();
    expect(
      (await a.hiddenNotes(v.id)).map((n) => n.body).toSet(),
      (await b.hiddenNotes(v.id)).map((n) => n.body).toSet(),
    );
    for (final c in clients) {
      expect(c.storage.pending(v.id), isEmpty);
    }
    final counts = clients
        .map((c) => c.storage.revisions(v.id).length)
        .toList();
    await a.renameVault(a.vaults.single, 'Renamed with hidden conflicts');
    await b.sync();
    expect(
      b.storage.revisions(v.id),
      hasLength(counts[1]),
      reason: 'Ordinary vault refresh must preserve hidden conflict history',
    );
    await a.sync();
    await b.sync();
    expect(
      clients.map((c) => c.storage.revisions(v.id).length).toList(),
      counts,
      reason: 'Settled conflict heads must not generate merge-of-merge loops',
    );
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);

  test('portable extra password syncs hidden notes while locked without ordinary projections', () async {
    final dirs = List.generate(
      2,
      (_) => Directory.systemTemp.createTempSync('hidden-e2ee-'),
    );
    final clients = [
      for (final dir in dirs)
        Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        ),
    ];
    addTearDown(() async {
      for (final c in clients) {
        await c.close();
      }
      for (final d in dirs) {
        d.deleteSync(recursive: true);
      }
    });
    final a = clients[0], b = clients[1];
    await a.initialize();
    await b.initialize();
    final recovery = await a.connect(
      server!,
      'hidden-e2ee-${DateTime.now().microsecondsSinceEpoch}@example.com',
      'disposable account password',
      register: true,
    );
    await a.createVault('ordinary');
    final v = a.vaults.single;
    await a.enableSync(v);
    await a.setHiddenPassword('portable extra password');
    await a.lockHidden();
    await a.sync();
    await b.connect(
      server,
      a.session!.email,
      'disposable account password',
      recoveryKey: recovery,
    );
    await b.sync();
    expect(
      b.hiddenPasswordSet,
      isTrue,
      reason:
          'Password configuration must sync even before the first hidden note',
    );
    expect(b.hiddenUnlocked, isFalse);
    expect(await a.unlockHidden('portable extra password'), isTrue);
    final note = await a.createHiddenNote(v.id);
    await a.save(
      note.copyWith(
        title: 'HIDDEN_TITLE_SENTINEL',
        body: 'HIDDEN_BODY_SENTINEL',
        folder: 'HIDDEN_FOLDER_SENTINEL',
        tags: ['HIDDEN_TAG_SENTINEL'],
      ),
    );
    await a.lockHidden();
    await a.sync();
    await b.sync();
    expect(
      b.hiddenPasswordSet,
      isTrue,
      reason: 'The portable password configuration must arrive without revealing the hidden key',
    );
    expect(b.hiddenUnlocked, isFalse);
    expect(await b.hiddenNotes(v.id), isEmpty);
    expect(b.notes[v.id], isEmpty);
    expect(await b.unlockHidden('wrong extra password'), isFalse);
    expect(await b.unlockHidden('portable extra password'), isTrue);
    final received = (await b.hiddenNotes(v.id)).single;
    expect(received.id, note.id);
    expect(received.body, 'HIDDEN_BODY_SENTINEL');
    expect(received.createdAt, note.createdAt);
    expect(received.tags, ['HIDDEN_TAG_SENTINEL']);
    for (final c in clients) {
      final db = (c.storage as NativeStorage).db;
      final dump = jsonEncode([
        db.select('SELECT * FROM documents'),
        db.select('SELECT * FROM revisions'),
        db.select('SELECT * FROM batches'),
      ]);
      for (final sentinel in [
        'HIDDEN_TITLE_SENTINEL',
        'HIDDEN_BODY_SENTINEL',
        'HIDDEN_FOLDER_SENTINEL',
        'HIDDEN_TAG_SENTINEL',
      ]) {
        expect(dump, isNot(contains(sentinel)));
      }
      expect(c.notes[v.id], isEmpty);
      expect(
        Directory('${(c.storage as NativeStorage).root}/markdown/${v.id}')
            .existsSync(),
        isFalse,
      );
    }
    // The account/vault key alone opens only an opaque inner envelope.
    for (final r in a.storage.revisions(v.id)) {
      final outer = await a.crypto.openCompat(
        a.unlocked[v.id]!,
        r.payload,
        r.aad,
        r.legacyAad,
      );
      expect(outer, isNot(contains('HIDDEN_BODY_SENTINEL')));
      expect(outer, isNot(contains('HIDDEN_TITLE_SENTINEL')));
    }
    // A hidden tombstone must travel encrypted and disappear from hidden lists.
    await b.save(received.copyWith(deleted: true));
    await b.lockHidden();
    await b.sync();
    await a.sync();
    expect(await a.unlockHidden('portable extra password'), isTrue);
    expect(await a.hiddenNotes(v.id), isEmpty);
    expect(await b.unlockHidden('portable extra password'), isTrue);
    expect(await b.hiddenNotes(v.id), isEmpty);
    // Permanent removal retires the opaque wire identity, including stale edits.
    await b.purgeNote(received.copyWith(deleted: true));
    await a.save(received.copyWith(body: 'STALE_HIDDEN_EDIT'));
    await a.sync();
    await b.sync();
    expect(await a.hiddenNotes(v.id), isEmpty);
    expect(a.storage.documents('hidden:${v.id}'), isEmpty);
    expect(b.storage.documents('hidden:${v.id}'), isEmpty);
  }, skip: server == null ? 'Requires disposable SILIQUE_TEST_SERVER' : false);
}
