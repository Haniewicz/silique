import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/core/models.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;

class ListStorage extends NativeStorage {
  ListStorage(super.root);
  @override
  Future<void> mirror(Note note) async {}
}

Future<Notebook> seedList(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('silique-sections-');
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: ListStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final vault = repo.vaults.single;
    final now = DateTime.now().toUtc();

    Future<String> addNote({
      required String title,
      required DateTime updatedAt,
      bool favorite = false,
    }) async {
      final note = await repo.createNote(vault.id);
      final created = Note(
        id: note.id,
        vaultId: note.vaultId,
        title: title,
        body: '$title body',
        updatedAt: updatedAt,
        createdAt: note.createdAt,
        favorite: favorite,
        folder: note.folder,
      );
      await repo.save(created);
      return created.id;
    }

    await addNote(title: 'Pinned note', updatedAt: now, favorite: true);
    await addNote(title: 'Today note', updatedAt: now);
    await addNote(
      title: 'Yesterday note',
      updatedAt: now.subtract(const Duration(days: 1)),
    );
    await addNote(
      title: 'Older note',
      updatedAt: now.subtract(const Duration(days: 5)),
    );
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await repo.storage.close();
      dir.deleteSync(recursive: true);
    });
  });
  return repo;
}

Future<void> mountAt(
  WidgetTester tester,
  Notebook repo, {
  required bool desktop,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = desktop
      ? const Size(1440, 900)
      : const Size(390, 844);
  addTearDown(() {
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
}

/// Vertical order of section headers among all header [Text]s in the list.
List<String> headerOrder(WidgetTester tester) {
  final headers = <String>['Przypięte', 'Dziś', 'Wczoraj', 'Starsze'];
  final found = <String>[];
  for (final h in headers) {
    if (find.text(h).evaluate().isNotEmpty) found.add(h);
  }
  // Reorder by vertical position to prove the visual sequence.
  final entries = found.map((h) {
    return (h, tester.getTopLeft(find.text(h)).dy);
  }).toList()
    ..sort((a, b) => a.$2.compareTo(b.$2));
  return entries.map((e) => e.$1).toList();
}

void main() {
  for (final desktop in [true, false]) {
    testWidgets(
      '${desktop ? 'desktop' : 'mobile'} list groups notes under pinned/today/yesterday/older headers',
      (tester) async {
        final repo = await seedList(tester);
        await mountAt(tester, repo, desktop: desktop);

        final notes = repo.notes[repo.vaults.single.id]!.values.toList();
        for (final note in notes) {
          expect(
            find.byKey(Key('note-card-${note.id}')),
            findsOneWidget,
            reason: 'each note appears exactly once in the list',
          );
        }
        expect(
          headerOrder(tester),
          ['Przypięte', 'Dziś', 'Wczoraj', 'Starsze'],
          reason: 'headers appear in the fixed section order',
        );

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}