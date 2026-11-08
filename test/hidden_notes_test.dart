import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class _Storage extends NativeStorage {
  _Storage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

void main() {
  Future<(Notebook, MemoryKeys, Directory)> open() async {
    final dir = Directory.systemTemp.createTempSync('hidden-notes-');
    final keys = MemoryKeys();
    final repo = Notebook(
      storage: _Storage(dir.path),
      keys: keys,
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Osobiste');
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    return (repo, keys, dir);
  }

  test(
    'hiding seals the note with the extra password and leaves no plaintext',
    () async {
      final (repo, _, dir) = await open();
      await expectLater(
        repo.hideNote(await repo.createNote(repo.vaults.single.id)),
        throwsStateError,
      );
      await repo.setHiddenPassword('hidden password 12345');
      expect(repo.hiddenUnlocked, isTrue);
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(
        note.copyWith(title: 'SECRET_TITLE', body: 'SECRET_BODY_TEXT'),
      );
      await repo.hideNote(repo.notes[vault.id]![note.id]!);
      expect(repo.notes[vault.id]!.containsKey(note.id), isFalse);
      final db = (repo.storage as NativeStorage).db;
      final documents = db.select('SELECT data FROM documents');
      expect(jsonEncode(documents), isNot(contains('SECRET_BODY_TEXT')));
      expect(jsonEncode(documents), isNot(contains('SECRET_TITLE')));
      expect(
        db.select('SELECT payload FROM revisions'),
        isNot(contains('SECRET_BODY_TEXT')),
      );
      final hiddenRow = db.select(
        'SELECT data FROM documents WHERE vault_id=? AND note_id=?',
        ['hidden:${vault.id}', note.id],
      ).single;
      expect(hiddenRow['data'], isNot(contains('SECRET_BODY_TEXT')));
    },
  );

  test(
    'wrong password is rejected and the right one reveals encrypted notes',
    () async {
      final (repo, _, _) = await open();
      await repo.setHiddenPassword('hidden password 12345');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: 'Ukryta', body: 'treść ukryta'));
      await repo.hideNote(repo.notes[vault.id]![note.id]!);
      await repo.lockHidden();
      expect(await repo.hiddenNotes(vault.id), isEmpty);
      expect(await repo.unlockHidden('wrong password'), isFalse);
      expect(repo.hiddenUnlocked, isFalse);
      expect(await repo.unlockHidden('hidden password 12345'), isTrue);
      final hidden = await repo.hiddenNotes(vault.id);
      expect(hidden, hasLength(1));
      expect(hidden.single.body, 'treść ukryta');
      expect(hidden.single.hidden, isTrue);
    },
  );

  test(
    'revealing a hidden note restores it to the vault with creation date',
    () async {
      final (repo, _, _) = await open();
      await repo.setHiddenPassword('hidden password 12345');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: 'Wracam', body: 'widoczna treść'));
      final created = repo.notes[vault.id]![note.id]!.createdAt;
      await repo.hideNote(repo.notes[vault.id]![note.id]!);
      expect(repo.notes[vault.id]!.containsKey(note.id), isFalse);
      final restored = await repo.unhideNote(vault.id, note.id);
      expect(restored.body, 'widoczna treść');
      expect(restored.hidden, isFalse);
      expect(restored.createdAt, created);
      expect(repo.notes[vault.id]![note.id]!.body, 'widoczna treść');
      expect(repo.storage.pending(vault.id), isNotEmpty);
      expect(repo.storage.documents('hidden:${vault.id}'), isEmpty);
    },
  );

  test(
    'inactivity auto-lock forgets the key and remembers the setting',
    () async {
      final (repo, keys, _) = await open();
      await repo.setHiddenPassword('hidden password 12345');
      await repo.setHiddenAutoLock(const Duration(seconds: 1));
      expect(repo.hiddenUnlocked, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(
        repo.hiddenUnlocked,
        isFalse,
        reason: 'Idle time must relock the hidden store',
      );
      await repo.setHiddenAutoLock(null);
      expect(await repo.unlockHidden('hidden password 12345'), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(
        repo.hiddenUnlocked,
        isTrue,
        reason: 'Auto-lock disabled keeps the store open',
      );
      expect(keys.values['silique.hidden.autoLock'], 'off');
    },
  );

  test(
    'background locking is configurable and persists for the next launch',
    () async {
      final (repo, keys, dir) = await open();
      await repo.setHiddenPassword('hidden password 12345');
      await repo.setHiddenAutoLock(const Duration(minutes: 5));
      await repo.setHiddenLockOnBackground(false);
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: 'Trwała', body: 'pozostaje ukryta'));
      await repo.hideNote(repo.notes[vault.id]![note.id]!);
      await repo.close();
      final reopened = Notebook(
        storage: _Storage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      await reopened.initialize();
      expect(reopened.hiddenPasswordSet, isTrue);
      expect(reopened.hiddenAutoLock, const Duration(minutes: 5));
      expect(reopened.hiddenLockOnBackground, isFalse);
      expect(reopened.hiddenUnlocked, isFalse);
      expect(await reopened.unlockHidden('hidden password 12345'), isTrue);
      expect(
        (await reopened.hiddenNotes(vault.id)).single.body,
        'pozostaje ukryta',
      );
      await reopened.close();
    },
  );
}
