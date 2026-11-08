import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/core/models.dart';
import 'package:silique/main.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil;

/// Creates a vault with [active] ordinary notes plus an optional deleted note.
Future<Notebook> seed(
  WidgetTester tester, {
  List<String> active = const ['Pierwsza'],
  String? deleted,
}) async {
  final dir = Directory.systemTemp.createTempSync('silique-close-tab-');
  late Notebook repo;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Close');
    final vault = repo.vaults.single;
    for (final title in active) {
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: title));
    }
    if (deleted != null) {
      final note = await repo.createNote(vault.id);
      await repo.save(note.copyWith(title: deleted, deleted: true));
    }
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

Finder card(Note note) => find.byKey(Key('note-card-${note.id}'));
Finder get title => find.byKey(const Key('note-title'), skipOffstage: false);

Note noteByTitle(Notebook repo, String title) => repo
    .notes[repo.vaults.single.id]!
    .values
    .firstWhere((n) => n.title == title);

String selectedTitle(WidgetTester tester) =>
    tester.widget<TextField>(title).controller!.text;

/// Taps the note card for [title], opening it as a tab if not already open.
Future<void> tapNote(WidgetTester tester, Notebook repo, String title) async {
  await tester.tap(card(noteByTitle(repo, title)));
  await tester.pumpAndSettle();
}

/// The close button of the tab whose label is [title].
///
/// The tab pill renders the label inside a `TextButton` next to the close
/// `IconButton`; the sidebar note card also shows [title] as a bare `Text`, so
/// we anchor on the `TextButton` ancestor to reach exactly one tab.
Finder closeTabButtonFor(String title) {
  final tabButton = find
      .ancestor(of: find.text(title), matching: find.byType(TextButton))
      .first;
  final row = find.ancestor(of: tabButton, matching: find.byType(Row)).first;
  return find.descendant(of: row, matching: find.byIcon(Icons.close));
}

Future<void> closeTab(WidgetTester tester, String title) async {
  await tester.tap(closeTabButtonFor(title));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('trashing the open note closes its tab and the editor', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['Pierwsza']);
    await mount(tester, repo);
    final note = noteByTitle(repo, 'Pierwsza');

    await tester.tap(card(note));
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);

    await tester.tap(card(note), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś do kosza'));
    // The save commits and then the open tab closes; wait for the editor to
    // actually clear rather than assuming a single settle drained the I/O.
    await drainUntil(tester, () => title.evaluate().isEmpty);

    expect(title, findsNothing);
    expect(find.text('Przestrzeń na dobrą myśl'), findsOneWidget);
    expect(repo.notes[note.vaultId]![note.id]!.deleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('permanently deleting the open note closes its tab', (
    tester,
  ) async {
    final repo = await seed(tester, active: const [], deleted: 'Usunięta');
    await mount(tester, repo);

    // Open the note from the trash.
    await tester.tap(find.text('Usunięte'));
    await tester.pumpAndSettle();
    final note = noteByTitle(repo, 'Usunięta');
    await tester.tap(card(note));
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);

    await tester.tap(card(note), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usuń bezpowrotnie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Potwierdź'));
    await drainUntil(tester, () => title.evaluate().isEmpty);

    expect(title, findsNothing);
    expect(find.text('Przestrzeń na dobrą myśl'), findsOneWidget);
    expect(repo.notes[note.vaultId]!.containsKey(note.id), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('trashing a non-open note keeps the other tab open', (
    tester,
  ) async {
    final repo = await seed(
      tester,
      active: const ['Pierwsza', 'Druga', 'Trzecia'],
    );
    await mount(tester, repo);

    await tester.tap(card(noteByTitle(repo, 'Pierwsza')));
    await tester.pumpAndSettle();
    expect(title, findsOneWidget);

    // Delete a note that is neither selected nor open in any tab.
    final second = noteByTitle(repo, 'Druga');
    await tester.tap(card(second), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś do kosza'));
    await drainUntil(
      tester,
      () => repo.notes[second.vaultId]![second.id]!.deleted,
    );

    // The open tab (first note) survives.
    expect(title, findsOneWidget);
    expect(tester.widget<TextField>(title).controller!.text, 'Pierwsza');
    expect(repo.notes[second.vaultId]![second.id]!.deleted, isTrue);
    expect(tester.takeException(), isNull);
  });

  // The notes are seeded newest-last so the app auto-opens 'A' on startup and
  // tapping A, B, C yields the tab order [A, B, C] (A leftmost, C rightmost).
  testWidgets('closing the selected tab returns to the last used note', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['C', 'B', 'A']);
    await mount(tester, repo);
    // A is auto-opened; open B and C so all three are tabs.
    await tapNote(tester, repo, 'B');
    await tapNote(tester, repo, 'C');

    // Use A, then C: A is the most recently used before C.
    await tapNote(tester, repo, 'A');
    await tapNote(tester, repo, 'C');
    expect(selectedTitle(tester), 'C');

    await closeTab(tester, 'C');
    expect(selectedTitle(tester), 'A');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the selected leftmost tab selects its right neighbor', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['C', 'B', 'A']);
    await mount(tester, repo);
    await tapNote(tester, repo, 'B');
    await tapNote(tester, repo, 'C');

    await tapNote(tester, repo, 'A');
    expect(selectedTitle(tester), 'A');

    await closeTab(tester, 'A');
    expect(selectedTitle(tester), 'B');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the selected rightmost tab selects its left neighbor', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['C', 'B', 'A']);
    await mount(tester, repo);
    await tapNote(tester, repo, 'B');
    await tapNote(tester, repo, 'C');

    await tapNote(tester, repo, 'C');
    expect(selectedTitle(tester), 'C');

    await closeTab(tester, 'C');
    expect(selectedTitle(tester), 'B');
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleting the selected note returns to the last used note', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['C', 'B', 'A']);
    await mount(tester, repo);
    await tapNote(tester, repo, 'B');
    await tapNote(tester, repo, 'C');

    await tapNote(tester, repo, 'A');
    await tapNote(tester, repo, 'C');
    expect(selectedTitle(tester), 'C');

    final c = noteByTitle(repo, 'C');
    await tester.tap(card(c), buttons: 2);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Przenieś do kosza'));

    // The trash commits, the tab closes, and the editor settles back on the
    // last-used note; wait for all three rather than only the storage commit.
    await drainUntil(
      tester,
      () =>
          repo.notes[c.vaultId]![c.id]!.deleted &&
          title.evaluate().isNotEmpty &&
          tester.widget<TextField>(title).controller!.text == 'A',
    );

    expect(selectedTitle(tester), 'A');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing an inactive tab does not change the selection', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['C', 'B', 'A']);
    await mount(tester, repo);
    await tapNote(tester, repo, 'B');
    await tapNote(tester, repo, 'C');

    await tapNote(tester, repo, 'B');
    expect(selectedTitle(tester), 'B');

    await closeTab(tester, 'A'); // inactive
    expect(selectedTitle(tester), 'B');

    await closeTab(tester, 'C'); // inactive
    expect(selectedTitle(tester), 'B');
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the last tab clears the editor without errors', (
    tester,
  ) async {
    final repo = await seed(tester, active: const ['B', 'A']);
    await mount(tester, repo);
    // 'A' is auto-opened (newest); close it — the only tab.
    expect(title, findsOneWidget);

    await closeTab(tester, 'A');
    expect(title, findsNothing);
    expect(find.text('Przestrzeń na dobrą myśl'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
