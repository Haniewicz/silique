import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:silique/services/api.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

void main() {
  late Notebook repo;
  late NativeStorage storage;
  late MemoryKeys keys;
  late Directory dir;
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('hidden-safe-');
    storage = NativeStorage(dir.path);
    keys = MemoryKeys();
    repo = Notebook(storage: storage, keys: keys, crypto: TestCrypto());
    await repo.initialize();
    await repo.createVault('Private');
    await repo.setHiddenPassword('additional password');
  });
  test(
    'moving a synced note without its owner connection must not erase it',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      final vault = repo.vaults.single..owner = 'https://example.com|owner';
      storage.putVault(vault);
      await expectLater(repo.hideNote(note), throwsStateError);
      expect(repo.notes[vault.id]!.containsKey(note.id), isTrue);
      expect(storage.documents('hidden:${vault.id}'), isEmpty);
    },
  );

  test(
    'failed server removal leaves the ordinary note and durable outbox intact',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      final vault = repo.vaults.single..owner = 'http://127.0.0.1|owner';
      vault.syncEnabled = true;
      storage.putVault(vault);
      repo.accountKey = repo.localKey;
      repo.session = Session(
        server: 'http://127.0.0.1',
        token: 'test',
        userId: 'owner',
        email: 'test@example.com',
      );
      repo.api = SiliqueApi(
        'http://127.0.0.1',
        client: MockClient((r) async => http.Response('{}', 503)),
      );
      await expectLater(repo.hideNote(note), throwsA(isA<ApiException>()));
      expect(repo.notes[vault.id]!.containsKey(note.id), isTrue);
      expect(storage.pending(vault.id), isNotEmpty);
      expect(storage.documents('hidden:${vault.id}'), isEmpty);
    },
  );

  test(
    'active SQLite files do not retain former plaintext after hiding',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      final marker = 'PLAIN-BEFORE-HIDING-UNIQUE-938472';
      final edited = note.copyWith(title: marker, body: marker);
      await repo.save(edited);
      // Force plaintext into database pages, not only the WAL.
      storage.db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await repo.hideNote(edited);
      for (final file in dir.listSync().whereType<File>()) {
        final bytes = file.readAsBytesSync();
        expect(
          utf8.decode(bytes, allowMalformed: true).contains(marker),
          isFalse,
          reason: file.path,
        );
      }
    },
  );

  test('reading the list does not extend user inactivity and lock emits a state event', () async {
    final events = <bool>[];
    final sub = repo.hiddenStateChanges.listen(
      (_) => events.add(repo.hiddenUnlocked),
    );
    await repo.setHiddenAutoLock(const Duration(milliseconds: 300));
    final note = await repo.createHiddenNote(repo.vaults.single.id);
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await repo.hiddenNotes(note.vaultId);
    }
    expect(repo.hiddenUnlocked, isFalse);
    expect(events, contains(false));
    await sub.cancel();
  });

  test(
    'corrupt hidden data is reported rather than silently disappearing',
    () async {
      final note = await repo.createHiddenNote(repo.vaults.single.id);
      storage.putDocument('hidden:${note.vaultId}', note.id, '{}');
      await expectLater(repo.hiddenNotes(note.vaultId), throwsA(anything));
    },
  );

  test(
    'local hide database failure rolls back the move as one transaction',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      storage.db.execute(
        "CREATE TRIGGER fail_hide BEFORE DELETE ON documents WHEN OLD.vault_id NOT LIKE 'hidden:%' BEGIN SELECT RAISE(ABORT, 'simulated delete failure'); END",
      );
      await expectLater(repo.hideNote(note), throwsA(anything));
      expect(storage.documents(note.vaultId), hasLength(1));
      expect(storage.documents('hidden:${note.vaultId}'), isEmpty);
      expect(repo.notes[note.vaultId]!.containsKey(note.id), isTrue);
    },
  );

  test(
    'restart completes plaintext cleanup from an interrupted move',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      await repo.save(
        note.copyWith(title: 'recovery secret', body: 'recovery body'),
      );
      final former = storage.documents(note.vaultId)[note.id]!;
      await repo.hideNote(repo.notes[note.vaultId]![note.id]!);
      // Simulate a crash after recovery ciphertext was committed but before the
      // ordinary document and Markdown copy could be cleaned up.
      storage.putDocument(note.vaultId, note.id, former);
      final mirror = File('${dir.path}/markdown/${note.vaultId}/${note.id}.md');
      mirror.parent.createSync(recursive: true);
      mirror.writeAsStringSync('recovery body');
      await repo.close();
      storage = NativeStorage(dir.path);
      repo = Notebook(storage: storage, keys: keys, crypto: TestCrypto());
      await repo.initialize();
      expect(repo.notes[note.vaultId], isEmpty);
      expect(storage.documents(note.vaultId), isEmpty);
      expect(mirror.existsSync(), isFalse);
      expect(repo.hiddenUnlocked, isFalse);
      expect(await repo.unlockHidden('additional password'), isTrue);
      expect(
        (await repo.hiddenNotes(note.vaultId)).single.body,
        'recovery body',
      );
    },
  );

  test('expired session stops exposing secrets even while persistence queue is blocked', () async {
    final gate = Completer<void>();
    final blocked = repo.serialized(() => gate.future);
    await repo.setHiddenAutoLock(const Duration(milliseconds: 50));
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(repo.hiddenUnlocked, isFalse);
    } finally {
      gate.complete();
      await blocked;
    }
    await repo.lockHidden();
  });

  test('hidden attachments larger than the note limit can move back without data loss', () async {
    final note = await repo.createNote(repo.vaults.single.id);
    final bytes = Uint8List(800000)..fillRange(0, 800000, 42);
    final uri = await repo.addImage(note.vaultId, note.id, bytes, 'image/png');
    await repo.save(note.copyWith(body: '![large]($uri)'));
    await repo.hideNote(repo.notes[note.vaultId]![note.id]!);
    final restored = await repo.unhideNote(note.vaultId, note.id);
    final match = RegExp(r'silique-image:([a-f0-9-]{36})')
        .firstMatch(restored.body);
    expect(match, isNotNull);
    expect(
      await repo.imageBytes(note.vaultId, match!.group(1)!),
      orderedEquals(bytes),
    );
  });

  test(
    'marking an ordinary note hidden is rejected unless moved transactionally',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      await expectLater(
        repo.save(note.copyWith(hidden: true, body: 'secret')),
        throwsStateError,
      );
      expect(storage.documents('hidden:${note.vaultId}'), isEmpty);
    },
  );

  test(
    'a revealed locally created hidden note becomes normally editable',
    () async {
      final hidden = await repo.createHiddenNote(repo.vaults.single.id);
      final restored = await repo.unhideNote(hidden.vaultId, hidden.id);
      await repo.save(restored.copyWith(body: 'ordinary edit'));
      expect(repo.notes[hidden.vaultId]![restored.id]!.body, 'ordinary edit');
    },
  );

  tearDown(() async {
    await repo.close();
    dir.deleteSync(recursive: true);
  });

  test('creating hidden never passes through ordinary storage and survives restart locked', () async {
    final Note note = await (repo as dynamic).createHiddenNote(
      repo.vaults.single.id,
    );
    expect(note.hidden, isTrue);
    await repo.save(
      note.copyWith(title: 'NEW SECRET', body: 'NEW SECRET BODY'),
    );
    expect(storage.documents(note.vaultId), isEmpty);
    expect(storage.pending(note.vaultId), isEmpty);
    await Future.sync(() => repo.lockHidden());
    expect(await repo.hiddenNotes(note.vaultId), isEmpty);
    expect(await repo.unlockHidden('additional password'), isTrue);
    expect(
      (await repo.hiddenNotes(note.vaultId)).single.body,
      'NEW SECRET BODY',
    );
  });

  test('lock drains saves already queued before forgetting the key', () async {
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.hideNote(note);
    final hidden = (await repo.hiddenNotes(note.vaultId)).single;
    final save = repo.save(hidden.copyWith(body: 'last keystroke'));
    await Future.sync(() => repo.lockHidden());
    await save;
    expect(repo.hiddenUnlocked, isFalse);
    expect(await repo.unlockHidden('additional password'), isTrue);
    expect(
      (await repo.hiddenNotes(note.vaultId)).single.body,
      'last keystroke',
    );
  });

  test(
    'reveal while the ordinary vault is locked preserves the hidden copy',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      await repo.hideNote(note);
      repo.lock(note.vaultId);
      await expectLater(
        repo.unhideNote(note.vaultId, note.id),
        throwsStateError,
      );
      expect(storage.documents('hidden:${note.vaultId}'), hasLength(1));
    },
  );

  test('reveal preserves flags tags and dates', () async {
    final note = await repo.createNote(repo.vaults.single.id);
    final value = note.copyWith(
      favorite: true,
      conflict: true,
      tags: ['secret'],
      folder: 'Folder',
    );
    await repo.save(value);
    await repo.hideNote(value);
    final restored = await repo.unhideNote(note.vaultId, note.id);
    expect(restored.favorite, isTrue);
    expect(restored.conflict, isTrue);
    expect(restored.tags, ['secret']);
    expect(restored.folder, 'Folder');
    expect(restored.createdAt, note.createdAt);
  });

  test('editing a hidden note never creates an ordinary document revision or mirror', () async {
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.hideNote(note);
    final hidden = (await repo.hiddenNotes(note.vaultId)).single;
    await repo.save(
      hidden.copyWith(title: 'SECRET edited', body: 'SECRET edited body'),
    );
    expect(repo.notes[note.vaultId], isEmpty);
    expect(storage.documents(note.vaultId), isEmpty);
    expect(storage.revisions(note.vaultId), isEmpty);
    expect(
      File('${dir.path}/markdown/${note.vaultId}/${note.id}.md').existsSync(),
      isFalse,
    );
    expect(
      (await repo.hiddenNotes(note.vaultId)).single.body,
      'SECRET edited body',
    );
  });

  test('stale ordinary save cannot resurrect an already hidden note', () async {
    final note = await repo.createNote(repo.vaults.single.id);
    await repo.hideNote(note);
    await expectLater(
      repo.save(note.copyWith(body: 'stale secret')),
      throwsStateError,
    );
    expect(storage.documents(note.vaultId), isEmpty);
  });

  test(
    'hiding embeds attachments before erasing their ordinary image records',
    () async {
      final note = await repo.createNote(repo.vaults.single.id);
      final bytes = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);
      final uri = await repo.addImage(
        note.vaultId,
        note.id,
        bytes,
        'image/png',
      );
      final withImage = note.copyWith(body: 'Photo ![private]($uri)');
      await repo.save(withImage);
      await repo.hideNote(withImage);
      final hidden = (await repo.hiddenNotes(note.vaultId)).single;
      expect(
        hidden.body,
        contains('data:image/png;base64,${base64Encode(bytes)}'),
      );
      expect(hidden.body, isNot(contains('silique-image:')));
      expect(storage.pendingImages(note.vaultId), isEmpty);
    },
  );
}
