import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

import 'package:silique/core/models.dart';

void main() {
  test(
    'hidden default is persisted; clearing survives lock and storage reopen',
    () async {
      final dir = Directory.systemTemp.createTempSync(
        'silique-hidden-default-',
      );
      final keys = MemoryKeys();
      Notebook make() => Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      var repo = make();
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.initialize();
      await repo.createVault('Private');
      final id = repo.vaults.single.id;
      await repo.setHiddenPassword('synthetic password');
      final note = await repo.createHiddenNote(id);
      expect(note.title, 'Bez tytułu');
      expect((await repo.hiddenNotes(id)).single.title, 'Bez tytułu');
      expect(repo.notes[id], isEmpty);
      await repo.save(note.copyWith(title: '', body: 'Private body'));
      await repo.lockHidden();
      await repo.close();
      repo = make();
      await repo.initialize();
      await repo.unlockHidden('synthetic password');
      expect((await repo.hiddenNotes(id)).single.title, isEmpty);
      expect((await repo.hiddenNotes(id)).single.body, 'Private body');
      expect(repo.notes[id], isEmpty);
    },
  );

  test(
    'default ordinary title is persisted and clearing survives storage reopen',
    () async {
      final dir = Directory.systemTemp.createTempSync('silique-creation-');
      final keys = MemoryKeys();
      Notebook make() => Notebook(
        storage: NativeStorage(dir.path),
        keys: keys,
        crypto: TestCrypto(),
      );
      var repo = make();
      addTearDown(() async {
        await repo.close();
        dir.deleteSync(recursive: true);
      });
      await repo.initialize();
      await repo.createVault('Creation regression');
      final vaultId = repo.vaults.single.id;
      final note = await repo.createNote(vaultId);
      expect(note.title, 'Bez tytułu');
      expect(repo.notes[vaultId]![note.id]!.title, 'Bez tytułu');
      final journal = await repo.createNote(vaultId, journalDate: '2026-10-19');
      expect(journal.title, '2026-10-19');
      expect(journal.journalDate, '2026-10-19');
      await repo.save(
        note.copyWith(title: '', body: 'Edited without entering a title'),
      );
      expect(repo.notes[vaultId]![note.id]!.createdAt, note.createdAt);
      await repo.close();
      repo = make();
      await repo.initialize();
      final reopened = repo.notes[vaultId]![note.id]!;
      expect(reopened.title, isEmpty);
      expect(reopened.body, 'Edited without entering a title');
      expect(reopened.createdAt, note.createdAt);
      expect(reopened.updatedAt, isNot(note.updatedAt));
      expect(repo.notes[vaultId]![journal.id]!.title, '2026-10-19');
    },
  );

  test('creation date survives edits and JSON with legacy fallback', () {
    final json = <String, dynamic>{
      'id': 'note',
      'vaultId': 'vault',
      'title': '',
      'body': '',
      'createdAt': '2020-01-01T00:00:00.000Z',
      'updatedAt': '2024-01-01T00:00:00.000Z',
    };
    final note = Note.fromJson(json);
    expect(
      note.copyWith(title: 'Edited').toJson()['createdAt'],
      json['createdAt'],
    );
    expect(
      Note.fromJson(note.toJson()).toJson()['createdAt'],
      json['createdAt'],
    );
    json.remove('createdAt');
    final legacy = Note.fromJson(json);
    expect(legacy.toJson()['createdAt'], json['updatedAt']);
    expect(
      legacy.copyWith(body: 'Edited').toJson()['createdAt'],
      json['updatedAt'],
    );
  });
}
