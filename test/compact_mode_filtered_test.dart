import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/theme.dart' show accent, muted;

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil, mount;

Finder treeList() => find.byKey(const Key('compact-tree-list'));

Finder notesPanel() => find.byKey(const Key('notes-list-panel'));

Finder noteCard(String id) => find.byKey(Key('note-card-$id'));

/// Every rendered `note-card-<id>` in the tree, regardless of indent.
Finder noteCards() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith('note-card-'),
);

Finder backRow() => find.byKey(const Key('compact-back-row'));

Finder titleField() => find.byKey(const Key('note-title'));

Finder footer() => find.byKey(const Key('sidebar-footer-actions'));

class FilteredFixture {
  const FilteredFixture({
    required this.repo,
    required this.deletedId,
    required this.favoriteId,
    required this.hiddenId,
    required this.normalIds,
  });

  final Notebook repo;
  final String deletedId;
  final String favoriteId;
  final String hiddenId;
  final List<String> normalIds;
}

/// Real-SQLite compact vault with the exact note set required by the card:
/// three ordinary notes (one inside `Alpha`), one deleted note, one favorite
/// note and one hidden note (the latter only consumed by the hidden test).
Future<FilteredFixture> filteredFixture(WidgetTester tester) async {
  final dir = Directory.systemTemp.createTempSync('compact-filtered-');
  late Notebook repo;
  late String deletedId, favoriteId, hiddenId;
  final normalIds = <String>[];
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final vault = repo.vaults.single;
    await repo.setCompactMode(vault, true);
    await repo.createFolder(vault, 'Alpha');

    Future<String> add(
      String title, {
      String folder = '',
      bool deleted = false,
      bool favorite = false,
    }) async {
      final note = await repo.createNote(vault.id, folder: folder);
      await repo.save(
        note.copyWith(
          title: title,
          body: '$title body',
          deleted: deleted,
          favorite: favorite,
        ),
      );
      return note.id;
    }

    normalIds.add(await add('Root note'));
    normalIds.add(await add('Alpha note', folder: 'Alpha'));
    normalIds.add(await add('Third note'));
    deletedId = await add('Deleted note', deleted: true);
    favoriteId = await add('Favorite note', favorite: true);

    // Hidden note: unlock the extra store first, then hide the note.
    await repo.setHiddenPassword('hidden password 12345');
    final hidden = await repo.createNote(vault.id);
    await repo.save(hidden.copyWith(title: 'Hidden note', body: 'secret'));
    hiddenId = hidden.id;
    await repo.hideNote(repo.notes[vault.id]![hiddenId]!);
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async => dir.deleteSync(recursive: true));
  });
  return FilteredFixture(
    repo: repo,
    deletedId: deletedId,
    favoriteId: favoriteId,
    hiddenId: hiddenId,
    normalIds: normalIds,
  );
}

/// Opens a note in the compact tree by expanding the root and tapping the
/// given card, so `note-title` shows in the editor.
Future<void> openRootNote(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(const Key('compact-root-toggle')));
  await tester.pumpAndSettle();
  await tester.tap(noteCard(id));
  await tester.pumpAndSettle();
  expect(titleField(), findsOneWidget);
}

void main() {
  testWidgets(
    'compact special filters keep the flat list in the 300px sidebar column '
    'and never show the classic notes panel',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);
      expect(treeList(), findsOneWidget);
      expect(notesPanel(), findsNothing);

      await openRootNote(tester, fx.normalIds.first);
      final editorBefore = tester.getRect(titleField()).left;

      Future<void> checkFilter(String? chip, String? footerLabel) async {
        if (chip != null) {
          await tester.tap(find.byKey(Key('compact-filter-$chip')));
        } else {
          await tester.tap(
            find.descendant(of: footer(), matching: find.text(footerLabel!)),
          );
        }
        await tester.pumpAndSettle();
        expect(notesPanel(), findsNothing);
        expect(treeList(), findsOneWidget);
        expect(tester.getRect(treeList()).width, closeTo(300, 1));
        final editorAfter = tester.getRect(titleField()).left;
        expect((editorAfter - editorBefore).abs(), lessThanOrEqualTo(1));
      }

      await checkFilter('Ostatnie', null);
      await checkFilter('Ulubione', null);
      await checkFilter(null, 'Usunięte');

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rendered note cards match filtered for trash, favorites and recent',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      Future<void> assertCards(Set<String> expected) async {
        final cards = noteCards();
        final rendered = <String>{
          for (final e in tester.widgetList(cards))
            (e.key as ValueKey<String>).value.substring('note-card-'.length),
        };
        expect(rendered, expected);
        final treeRect = tester.getRect(treeList());
        for (final id in rendered) {
          final rect = tester.getRect(noteCard(id));
          expect(rect.right, lessThanOrEqualTo(treeRect.right + 1));
        }
      }

      // Trash → only the deleted note.
      await tester.tap(
        find.descendant(of: footer(), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();
      expect(treeList(), findsOneWidget);
      expect(notesPanel(), findsNothing);
      await assertCards({fx.deletedId});

      // Favorites → only the favorite note.
      await tester.tap(find.byKey(const Key('compact-filter-Ulubione')));
      await tester.pumpAndSettle();
      await assertCards({fx.favoriteId});

      // Recent → every non-deleted note (3 ordinary + favorite).
      await tester.tap(find.byKey(const Key('compact-filter-Ostatnie')));
      await tester.pumpAndSettle();
      await assertCards({...fx.normalIds, fx.favoriteId});

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'back row sits above the first note and returns to the folder tree',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      await tester.tap(
        find.descendant(of: footer(), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();
      expect(backRow(), findsOneWidget);
      expect(
        tester.getRect(backRow()).top,
        lessThan(tester.getRect(noteCard(fx.deletedId)).top),
      );

      await tester.tap(backRow());
      await tester.pumpAndSettle();
      expect(backRow(), findsNothing);
      expect(find.byKey(const Key('compact-root-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const Key('compact-root-toggle')));
      await tester.pumpAndSettle();
      expect(noteCard(fx.normalIds.first), findsOneWidget);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'hidden filter renders the flat list and the back row forgets plaintext',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      // The extra store is already unlocked while the fixture is created.
      await tester.tap(find.byKey(const Key('hidden-folder-nav')));
      await tester.pumpAndSettle();
      // Hidden notes are read through the encrypted store, so the list arrives
      // after real I/O — pumpAndSettle alone does not wait for it.
      await drainUntil(
        tester,
        () => noteCard(fx.hiddenId).evaluate().isNotEmpty,
      );
      expect(notesPanel(), findsNothing);
      expect(treeList(), findsOneWidget);
      expect(backRow(), findsOneWidget);
      expect(noteCard(fx.hiddenId), findsOneWidget);

      await tester.tap(backRow());
      await tester.pumpAndSettle();
      expect(backRow(), findsNothing);
      expect(find.byKey(const Key('compact-root-toggle')), findsOneWidget);
      await tester.tap(find.byKey(const Key('compact-root-toggle')));
      await tester.pumpAndSettle();
      expect(noteCard(fx.normalIds.first), findsOneWidget);
      // The hidden title must not leak back into the ordinary tree.
      expect(find.text('Hidden note'), findsNothing);

      expect(tester.takeException(), isNull);
      // Visiting hidden notes arms the repository auto-lock timer; lock the
      // store explicitly so the test does not end with a pending timer.
      await tester.runAsync(() => fx.repo.lockHidden());
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'compact filter chips highlight when active',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      Color chipColor(String f) {
        final container = tester.widget<Container>(
          find.descendant(
            of: find.byKey(Key('compact-filter-$f')),
            matching: find.byType(Container),
          ),
        );
        return (container.decoration! as BoxDecoration).color!;
      }

      Color chipText(String f) {
        final text = tester.widget<Text>(
          find.descendant(
            of: find.byKey(Key('compact-filter-$f')),
            matching: find.byType(Text),
          ),
        );
        return text.style!.color!;
      }

      Future<void> expectHighlighted(String f, bool highlighted) async {
        if (highlighted) {
          expect(chipColor(f), accent.withValues(alpha: .12));
          expect(chipText(f), accent);
        } else {
          expect(chipColor(f), Colors.transparent);
          expect(chipText(f), muted);
        }
      }

      // Idle: neither chip highlighted.
      await expectHighlighted('Ostatnie', false);

      await tester.tap(find.byKey(const Key('compact-filter-Ostatnie')));
      await tester.pumpAndSettle();
      await expectHighlighted('Ostatnie', true);
      await expectHighlighted('Ulubione', false);

      await tester.tap(find.byKey(const Key('compact-filter-Ulubione')));
      await tester.pumpAndSettle();
      await expectHighlighted('Ulubione', true);
      await expectHighlighted('Ostatnie', false);

      // Back to all → no chip highlighted.
      await tester.tap(backRow());
      await tester.pumpAndSettle();
      await expectHighlighted('Ostatnie', false);
      await expectHighlighted('Ulubione', false);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'footer Usunięte entry keeps its accent highlight while trash is active',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      Color deletedMaterial() {
        final material = tester.widget<Material>(
          find.ancestor(
            of: find.descendant(
              of: footer(),
              matching: find.text('Usunięte'),
            ),
            matching: find.byType(Material),
          ).first,
        );
        return material.color!;
      }

      await tester.tap(
        find.descendant(of: footer(), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();
      expect(deletedMaterial(), accent.withValues(alpha: .12));

      await tester.tap(backRow());
      await tester.pumpAndSettle();
      expect(deletedMaterial(), Colors.transparent);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mobile drawer shows the filtered flat list without the notes panel',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo); // desktop: false

      // First, filter to trash through the drawer footer (which closes the
      // drawer on tap), then reopen the drawer to inspect its filtered tree.
      await tester.tap(find.byTooltip('Foldery i vaulty'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(Drawer), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Foldery i vaulty'));
      await tester.pumpAndSettle();
      final drawer = find.byType(Drawer);

      expect(
        find.descendant(of: drawer, matching: treeList()),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: noteCard(fx.deletedId)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: drawer, matching: backRow()),
        findsOneWidget,
      );
      expect(notesPanel(), findsNothing);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'note-search-field still filters within the active compact filter',
    (tester) async {
      final fx = await filteredFixture(tester);
      await mount(tester, fx.repo, desktop: true);

      await tester.tap(
        find.descendant(of: footer(), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-search-field')), findsOneWidget);
      expect(noteCard(fx.deletedId), findsOneWidget);

      await tester.enterText(
        find.descendant(
          of: find.byKey(const Key('note-search-field')),
          matching: find.byType(TextField),
        ),
        'Deleted',
      );
      await tester.pumpAndSettle();
      expect(noteCard(fx.deletedId), findsOneWidget);
      expect(noteCards(), findsOneWidget);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an empty filter shows the no-notes message while the back row stays',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('compact-empty-');
      late Notebook repo;
      await tester.runAsync(() async {
        repo = Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Phone');
        final vault = repo.vaults.single;
        await repo.setCompactMode(vault, true);
        final note = await repo.createNote(vault.id);
        await repo.save(note.copyWith(title: 'Only note'));
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final close = repo.close().then((_) => closed = true);
        await drainUntil(tester, () => closed);
        await close;
        await tester.runAsync(() async => dir.deleteSync(recursive: true));
      });

      await mount(tester, repo, desktop: true);
      await tester.tap(
        find.descendant(of: footer(), matching: find.text('Usunięte')),
      );
      await tester.pumpAndSettle();
      expect(treeList(), findsOneWidget);
      expect(notesPanel(), findsNothing);
      expect(backRow(), findsOneWidget);
      expect(find.text('Brak notatek'), findsOneWidget);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
