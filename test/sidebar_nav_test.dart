import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

Future<Notebook> seed(WidgetTester tester, {bool compact = false}) async {
  final dir = Directory.systemTemp.createTempSync('silique-sidebar-nav-');
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Nav');
    final vault = repo.vaults.single;
    for (final title in ['Alfa notatka', 'Beta notatka']) {
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: title));
    }
    if (compact) await repo.setCompactMode(vault, true);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });
  return repo;
}

Future<void> mount(WidgetTester tester, Notebook repo) async {
  await tester.binding.setSurfaceSize(const Size(1380, 880));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [notebookProvider.overrideWithValue(repo)],
      child: const SiliqueApp(),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get searchField => find.descendant(
  of: find.byKey(const Key('note-search-field')),
  matching: find.byType(TextField),
);

void main() {
  for (final compact in [false, true]) {
    final layout = compact ? 'compact' : 'desktop';
    testWidgets('$layout sidebar has no search nav and renames the journal', (
      tester,
    ) async {
      final repo = await seed(tester, compact: compact);
      await mount(tester, repo);

      // The search navigation entry is gone; the journal entry is renamed.
      expect(find.text('Szukaj'), findsNothing);
      expect(find.text('Nowy wpis w dzienniku'), findsOneWidget);
      expect(find.text('Dziennik'), findsNothing);

      // The search field itself still works and filters the list.
      final notes = repo.notes[repo.vaults.single.id]!.values;
      final alfa = notes.firstWhere((n) => n.title == 'Alfa notatka');
      final beta = notes.firstWhere((n) => n.title == 'Beta notatka');
      await tester.enterText(searchField, 'Alfa');
      await tester.pumpAndSettle();
      expect(find.byKey(Key('note-card-${alfa.id}')), findsOneWidget);
      expect(find.byKey(Key('note-card-${beta.id}')), findsNothing);

      expect(tester.takeException(), isNull);
    });
  }
}
