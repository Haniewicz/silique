import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

void main() {
  Notebook makeRepo(Directory root) => Notebook(
    storage: NativeStorage(root.path),
    keys: MemoryKeys(),
    crypto: TestCrypto(),
  );

  test(
    'setNoteColor saves, noteColorsOf reads, and null removes the entry',
    () async {
      final root = Directory.systemTemp.createTempSync('silique-note-colors-');
      final repo = makeRepo(root);
      addTearDown(() async {
        await repo.close();
        root.deleteSync(recursive: true);
      });
      await repo.initialize();
      await repo.createVault('Notes');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);

      expect(repo.noteColorsOf(vault.id), isEmpty);
      expect(await repo.setNoteColor(vault, note.id, 0xff112233), isTrue);
      expect(repo.noteColorsOf(vault.id), {note.id: 0xff112233});
      // Clearing an already-absent entry is a no-op, not an error.
      expect(await repo.setNoteColor(vault, note.id, null), isTrue);
      expect(repo.noteColorsOf(vault.id), isEmpty);
      expect(await repo.setNoteColor(vault, note.id, null), isTrue);
    },
  );

  test('setting a note color never rewrites the note document', () async {
    final root = Directory.systemTemp.createTempSync('silique-note-color-doc-');
    final repo = makeRepo(root);
    addTearDown(() async {
      await repo.close();
      root.deleteSync(recursive: true);
    });
    await repo.initialize();
    await repo.createVault('Notes');
    final vault = repo.vaults.single;
    final note = await repo.createNote(vault.id);
    await repo.save(note.copyWith(title: 'Title', body: 'Body'));
    final before = repo.notes[vault.id]![note.id]!;

    await repo.setNoteColor(vault, note.id, 0xffff0000);
    final after = repo.notes[vault.id]![note.id]!;
    expect(after.body, before.body);
    expect(after.title, before.title);
    expect(after.updatedAt, before.updatedAt);
  });

  // ── UI tests ──────────────────────────────────────────────────────────

  Future<Notebook> mountHome(
    WidgetTester tester,
    Future<void> Function(Notebook repo) setup,
  ) async {
    late Directory root;
    late Notebook repo;
    await tester.runAsync(() async {
      root = Directory.systemTemp.createTempSync('silique-note-colors-ui-');
      repo = Notebook(
        storage: NativeStorage(root.path),
        keys: MemoryKeys(),
        crypto: TestCrypto(),
      );
      await repo.initialize();
      await setup(repo);
    });
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      var closed = false;
      final close = repo.close().then((_) => closed = true);
      await drainUntil(tester, () => closed);
      await close;
      await tester.runAsync(() async => root.deleteSync(recursive: true));
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [notebookProvider.overrideWithValue(repo)],
        child: const SiliqueApp(),
      ),
    );
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets(
    'two notes in the same vault render icons with an identical color',
    (tester) async {
      late String regularId;
      late String journalId;
      await mountHome(tester, (repo) async {
        await repo.createVault('Notes');
        final vault = repo.vaults.single;
        final regular = await repo.createNote(vault.id);
        final journal = await repo.createNote(
          vault.id,
          journalDate: '2026-11-06',
        );
        await repo.save(regular.copyWith(title: 'Regular'));
        await repo.save(journal.copyWith(title: 'Journal'));
        regularId = regular.id;
        journalId = journal.id;
      });

      final regularIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('note-card-$regularId')),
          matching: find.byIcon(Icons.description_outlined),
        ),
      );
      final journalIcon = tester.widget<Icon>(
        find.descendant(
          of: find.byKey(Key('note-card-$journalId')),
          matching: find.byIcon(Icons.calendar_month),
        ),
      );
      expect(regularIcon.color, journalIcon.color);
    },
  );

  testWidgets('a note with an explicit color renders its icon in that color', (
    tester,
  ) async {
    late String noteId;
    await mountHome(tester, (repo) async {
      await repo.createVault('Notes');
      final vault = repo.vaults.single;
      final note = await repo.createNote(vault.id);
      await repo.setNoteColor(vault, note.id, 0xff00ff00);
      noteId = note.id;
    });

    final icon = tester.widget<Icon>(
      find.descendant(
        of: find.byKey(Key('note-card-$noteId')),
        matching: find.byIcon(Icons.description_outlined),
      ),
    );
    expect(icon.color, const Color(0xff00ff00));
  });
}
