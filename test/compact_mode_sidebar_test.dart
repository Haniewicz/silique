import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/storage/native_storage.dart';
import 'package:silique/ui/theme.dart' show accent;

import 'core_test.dart' show MemoryKeys, TestCrypto;
import 'hidden_notes_home_test.dart' show drainUntil, mount;

Finder searchField() => find.byKey(const Key('note-search-field'));

Finder searchInput() =>
    find.descendant(of: searchField(), matching: find.byType(TextField));

Finder treeList() => find.byKey(const Key('compact-tree-list'));

Finder sidebarToggle() => find.byKey(const Key('sidebar-toggle-notes-list'));

Finder selectMode() => find.byKey(const Key('select-mode'));

Finder noteCard(String id) => find.byKey(Key('note-card-$id'));

/// Every rendered `note-card-<id>` in the tree. Collapsed folders drop their
/// note rows entirely (they are not built offstage), so this counts exactly
/// the visible note rows in the compact tree.
Finder noteCards() => find.byWidgetPredicate(
  (w) =>
      w.key is ValueKey<String> &&
      (w.key as ValueKey<String>).value.startsWith('note-card-'),
);

Finder titleField() => find.byKey(const Key('note-title'));

/// Folder labels scoped to the merged tree: the open editor also renders the
/// selected note's folder, so bare text finders are ambiguous.
Finder treeText(String label) =>
    find.descendant(of: treeList(), matching: find.text(label));

Finder folderIcon(String path) => find.byKey(Key('folder-icon-$path'));

Finder folderRow(String path) => find.byKey(Key('folder-row-$path'));

/// The 1px separators drawn between the sidebar / notes rail / editor panels.
/// The editor toolbar uses its own 15px `VerticalDivider`s, so a plain
/// `find.byType(VerticalDivider)` would over-count.
Finder panelDividers() => find.byWidgetPredicate(
  (widget) => widget is VerticalDivider && widget.width == 1,
);

class TreeFixture {
  TreeFixture({
    required this.repo,
    required this.rootNote,
    required this.alphaNote,
    required this.betaNote,
  });

  final Notebook repo;
  final String rootNote;
  final String alphaNote;
  final String betaNote;
}

/// Real-SQLite vault: a root note plus `Alpha` and `Alpha/Beta`, each holding
/// one note, so the tree exercises two nesting levels and root-level notes.
Future<TreeFixture> treeFixture(
  WidgetTester tester, {
  bool compact = false,
}) async {
  final dir = Directory.systemTemp.createTempSync('compact-sidebar-');
  late Notebook repo;
  late String rootId, alphaId, betaId;
  await tester.runAsync(() async {
    repo = Notebook(
      storage: NativeStorage(dir.path),
      keys: MemoryKeys(),
      crypto: TestCrypto(),
    );
    await repo.initialize();
    await repo.createVault('Phone');
    final vault = repo.vaults.single;
    await repo.createFolder(vault, 'Alpha');
    await repo.createFolder(vault, 'Alpha/Beta');
    final root = await repo.createNote(vault.id);
    await repo.save(root.copyWith(title: 'Root note'));
    final alpha = await repo.createNote(vault.id, folder: 'Alpha');
    await repo.save(alpha.copyWith(title: 'Alpha note'));
    final beta = await repo.createNote(vault.id, folder: 'Alpha/Beta');
    await repo.save(beta.copyWith(title: 'Beta note'));
    if (compact) await repo.setCompactMode(vault, true);
    rootId = root.id;
    alphaId = alpha.id;
    betaId = beta.id;
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    var closed = false;
    final close = repo.close().then((_) => closed = true);
    await drainUntil(tester, () => closed);
    await close;
    await tester.runAsync(() async {
      dir.deleteSync(recursive: true);
    });
  });
  return TreeFixture(
    repo: repo,
    rootNote: rootId,
    alphaNote: alphaId,
    betaNote: betaId,
  );
}

void main() {
  testWidgets('folder selection reopens the collapsed notes list on desktop', (
    tester,
  ) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo, desktop: true);
    expect(searchField(), findsOneWidget);
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);
    expect(noteCard(fx.alphaNote), findsNothing);
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(
      searchField(),
      findsOneWidget,
      reason: 'choosing a folder restores the collapsed notes list',
    );
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(
      noteCard(fx.rootNote),
      findsNothing,
      reason: 'the reopened list is scoped to the chosen folder',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the collapsed notes list stays collapsed without a folder', (
    tester,
  ) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);
    await tester.tap(find.text('Usunięte'));
    await tester.pumpAndSettle();
    expect(
      searchField(),
      findsNothing,
      reason: 'switching sections without a folder keeps the list collapsed',
    );
    expect(sidebarToggle(), findsOneWidget);
    expect(
      tester.widget<IconButton>(sidebarToggle()).tooltip,
      'Pokaż listę notatek',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile drawer folder selection shows the folder notes', (
    tester,
  ) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(Drawer), matching: find.text('Alpha')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(searchField(), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(noteCard(fx.rootNote), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact mode renders one hierarchical folder+notes tree', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    expect(treeList(), findsOneWidget);
    expect(
      sidebarToggle(),
      findsOneWidget,
      reason: 'the sidebar toggle now hides the entire compact sidebar',
    );
    expect(
      selectMode(),
      findsNothing,
      reason: 'the classic notes panel is merged into the sidebar',
    );
    // Default: root and all folders collapsed — no notes visible.
    expect(treeText('Alpha'), findsOneWidget);
    expect(
      treeText('Beta'),
      findsNothing,
      reason: 'nested folders inside collapsed parents are hidden',
    );
    expect(
      noteCard(fx.rootNote),
      findsNothing,
      reason: 'root notes collapsed by default',
    );
    expect(
      noteCard(fx.alphaNote),
      findsNothing,
      reason: 'Alpha folder collapsed by default',
    );
    expect(
      noteCard(fx.betaNote),
      findsNothing,
      reason: 'Beta folder collapsed by default',
    );

    // Expand root → root notes appear.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsNothing);

    // Expand Alpha → its notes appear.  Beta still hidden.
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(
      treeText('Beta'),
      findsOneWidget,
      reason: 'nested folder visible when parent is expanded',
    );
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(
      noteCard(fx.betaNote),
      findsNothing,
      reason: 'Beta still collapsed within expanded Alpha',
    );

    // Notes sit under their own folder: deeper folders indent further.
    final rootDx = tester.getTopLeft(noteCard(fx.rootNote)).dx;
    final alphaDx = tester.getTopLeft(noteCard(fx.alphaNote)).dx;
    expect(alphaDx, greaterThan(rootDx));
    // The search field stays above the merged list and keeps its menu hook.
    expect(
      tester.getTopLeft(searchField()).dy,
      lessThan(tester.getTopLeft(find.text('Wszystkie notatki')).dy),
      reason: 'compact search sits above the merged list',
    );
    expect(
      tester.widget<TextField>(searchInput()).contextMenuBuilder,
      isNotNull,
      reason: 'the relocated field keeps siliqueTextContextMenu',
    );
    expect(find.byKey(const Key('compact-filter-Ostatnie')), findsOneWidget);
    expect(find.byKey(const Key('compact-filter-Ulubione')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact folder tap toggles the subtree, note tap opens it', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // All collapsed by default.  Expand root and Alpha.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(treeText('Beta'), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(noteCard(fx.rootNote), findsOneWidget);
    // Collapse Alpha → its children and notes disappear.
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(treeText('Beta'), findsNothing);
    expect(noteCard(fx.alphaNote), findsNothing);
    expect(noteCard(fx.betaNote), findsNothing);
    expect(
      noteCard(fx.rootNote),
      findsOneWidget,
      reason: 'root-level notes stay visible while a subtree is collapsed',
    );
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(treeText('Beta'), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(
      noteCard(fx.betaNote),
      findsNothing,
      reason: 'Beta still collapsed — must expand both levels separately',
    );
    await tester.tap(folderIcon('Alpha/Beta'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.betaNote), findsOneWidget);
    await tester.tap(noteCard(fx.rootNote));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(titleField()).controller!.text,
      'Root note',
      reason: 'tapping a note in the merged tree opens it in the editor',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact mobile drawer opens notes from the merged tree', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    final drawer = find.byType(Drawer);
    expect(find.descendant(of: drawer, matching: treeList()), findsOneWidget);
    expect(
      find.descendant(of: drawer, matching: searchField()),
      findsNothing,
      reason: 'the drawer tree relies on the main list search field',
    );
    // Expand root and Alpha to reveal Beta note.
    await tester.tap(
      find.descendant(
        of: drawer,
        matching: find.byKey(const Key('compact-root-toggle')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: drawer, matching: folderIcon('Alpha')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: drawer, matching: folderIcon('Alpha/Beta')),
    );
    await tester.pumpAndSettle();
    final card = find.descendant(of: drawer, matching: noteCard(fx.betaNote));
    expect(card, findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsNothing);
    expect(
      tester.widget<TextField>(titleField()).controller!.text,
      'Beta note',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact toggle rebuilds the sidebar live and survives restart', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('compact-live-');
    final keys = MemoryKeys();
    final crypto = TestCrypto();
    Notebook make() =>
        Notebook(storage: NativeStorage(dir.path), keys: keys, crypto: crypto);
    late Notebook repo;
    late String alphaId;
    addTearDown(() async {
      await repo.close();
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      repo = make();
      await repo.initialize();
      await repo.createVault('Phone');
      final vault = repo.vaults.single;
      await repo.createFolder(vault, 'Alpha');
      final note = await repo.createNote(vault.id, folder: 'Alpha');
      await repo.save(note.copyWith(title: 'Live sentinel'));
      alphaId = note.id;
    });
    await mount(tester, repo, desktop: true);
    expect(treeList(), findsNothing);
    expect(selectMode(), findsOneWidget);

    await tester.tap(find.byTooltip('Ustawienia synchronizacji'));
    await tester.pumpAndSettle();
    // The compact switch lives on the Appearance tab now.
    await tester.tap(find.byKey(const Key('settings-tab-appearance')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('compact-mode-toggle'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    // The metadata write runs through real SQLite; pump bounded frames.
    await drainUntil(tester, () => repo.compactModeOf(repo.vaults.single.id));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(
      treeList(),
      findsOneWidget,
      reason: 'the sidebar switches to the merged tree without a restart',
    );
    expect(
      sidebarToggle(),
      findsOneWidget,
      reason:
          'compact sidebar toggle is now visible for hiding the whole sidebar',
    );
    // Default collapsed: expand Alpha to see its note.
    expect(noteCard(alphaId), findsNothing);
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(alphaId), findsOneWidget);

    // A fresh Notebook over the same storage keeps the preference.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      await repo.close();
      repo = make();
      await repo.initialize();
    });
    expect(repo.compactModeOf(repo.vaults.single.id), isTrue);
    await mount(tester, repo, desktop: true);
    expect(treeList(), findsOneWidget);
    expect(noteCard(alphaId), findsNothing);
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(alphaId), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search filters the compact tree and ignores collapsed state', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // Expand root so we can see root notes after clearing search.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.betaNote), findsNothing);
    await tester.enterText(searchInput(), 'Beta');
    await tester.pumpAndSettle();
    expect(
      noteCard(fx.betaNote),
      findsOneWidget,
      reason: 'searching expands collapsed subtrees to reveal matches',
    );
    expect(noteCard(fx.alphaNote), findsNothing);
    expect(noteCard(fx.rootNote), findsNothing);
    expect(
      treeText('Alpha'),
      findsOneWidget,
      reason: 'ancestors of a match stay in the pruned tree',
    );
    await tester.enterText(searchInput(), 'brak-takiej-notatki');
    await tester.pumpAndSettle();
    expect(treeText('Nie znaleziono notatek'), findsOneWidget);
    await tester.enterText(searchInput(), '');
    await tester.pumpAndSettle();
    expect(
      noteCard(fx.betaNote),
      findsNothing,
      reason: 'clearing the query restores the collapsed subtree state',
    );
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search keeps filtering the classic notes list', (tester) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo, desktop: true);
    expect(treeList(), findsNothing);
    await tester.enterText(searchInput(), 'Root');
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('special filters keep the compact sidebar with a flat list', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    expect(treeList(), findsOneWidget);
    await tester.tap(find.byKey(const Key('compact-filter-Ostatnie')));
    await tester.pumpAndSettle();
    expect(
      treeList(),
      findsOneWidget,
      reason: 'special filters stay inside the single compact sidebar column',
    );
    expect(find.byKey(const Key('compact-back-row')), findsOneWidget);
    expect(selectMode(), findsNothing);
    expect(find.byKey(const Key('notes-list-panel')), findsNothing);
    await tester.tap(find.byKey(const Key('compact-back-row')));
    await tester.pumpAndSettle();
    expect(treeList(), findsOneWidget);
    expect(find.byKey(const Key('compact-back-row')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // ── New compact behaviour : default-collapsed root & folders ──────────

  testWidgets('entering compact mode: folder rows visible, zero notes, '
      'root also collapsed', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    expect(treeList(), findsOneWidget);
    // Folder rows are visible.
    expect(treeText('Alpha'), findsOneWidget);
    // Root folder row is visible.
    expect(treeText('Wszystkie notatki'), findsOneWidget);
    // No notes at all — root and all folders collapsed.
    expect(noteCard(fx.rootNote), findsNothing);
    expect(noteCard(fx.alphaNote), findsNothing);
    expect(noteCard(fx.betaNote), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tap "Wszystkie notatki" toggles root notes', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // Root collapsed.
    expect(noteCard(fx.rootNote), findsNothing);
    // Tap root toggle → root notes appear.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    // Tap again → root notes disappear.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('folder expand/collapse: nested notes appear only after '
      'both levels are expanded', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // Expand Alpha.
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    // Alpha notes should appear.
    expect(noteCard(fx.alphaNote), findsOneWidget);
    // Beta folder is now visible but its notes are still collapsed.
    expect(treeText('Beta'), findsOneWidget);
    expect(
      noteCard(fx.betaNote),
      findsNothing,
      reason: 'Beta still collapsed inside expanded Alpha',
    );
    // Expand Beta too.
    await tester.tap(folderIcon('Alpha/Beta'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.betaNote), findsOneWidget);
    // Collapse Alpha — both Alpha and Beta notes disappear.
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.alphaNote), findsNothing);
    expect(noteCard(fx.betaNote), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact note icon size 16 and title fontSize 12 match '
      'the folder row', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // Expand root so a note is visible.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);

    // Find the icon inside the note card (it is a plain Icon, not a Container
    // child in compact mode).  The note card has an Icon widget.
    final noteIconFinder = find.descendant(
      of: noteCard(fx.rootNote),
      matching: find.byType(Icon),
    );
    expect(noteIconFinder, findsWidgets);
    final noteIcon = tester.widget<Icon>(noteIconFinder.first);
    expect(
      noteIcon.size,
      16,
      reason: 'compact note icon must match folder icon size',
    );

    // The note title is a Text with the note's title.
    final noteTitleFinder = find.descendant(
      of: noteCard(fx.rootNote),
      matching: find.text('Root note'),
    );
    expect(noteTitleFinder, findsOneWidget);
    final noteTitle = tester.widget<Text>(noteTitleFinder);
    final noteStyle = noteTitle.style;
    expect(
      noteStyle?.fontSize,
      12,
      reason: 'compact note title fontSize must match folder label',
    );
    expect(
      noteStyle?.fontWeight,
      isNot(FontWeight.w600),
      reason: 'compact note title must not be bold',
    );

    // Compare against a real folder label — same fontSize.
    final folderLabel = tester.widget<Text>(treeText('Alpha'));
    expect(folderLabel.style?.fontSize, 12, reason: 'folder label baseline');
    expect(
      noteStyle?.fontSize,
      folderLabel.style?.fontSize,
      reason: 'note and folder labels must share the same fontSize',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('search shows matches despite collapsed folders', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    // All collapsed — no notes visible.
    expect(noteCard(fx.betaNote), findsNothing);
    // Searching reveals the match.
    await tester.enterText(searchInput(), 'Beta');
    await tester.pumpAndSettle();
    expect(noteCard(fx.betaNote), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // ── Sticky & scroll tests (new compact sidebar) ─────────────────

  testWidgets('sticky search field is in a SliverPersistentHeader in '
      'compact sidebar', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.pumpAndSettle();
    expect(treeList(), findsOneWidget);

    // The search field starts below the SILIQUE header (before any scroll
    // would pin it).
    final searchTop = tester.getTopLeft(searchField()).dy;
    final headerBottom = tester.getRect(find.text('SILIQUE')).bottom;
    expect(
      searchTop,
      greaterThan(headerBottom),
      reason: 'search field is rendered below the SILIQUE header',
    );

    // The compact sidebar uses a single CustomScrollView for the main content.
    expect(find.byType(CustomScrollView), findsOneWidget);

    // A SliverPersistentHeader is used for the sticky search field.
    expect(
      find.byType(SliverPersistentHeader),
      findsOneWidget,
      reason: 'the search field is wrapped in a pinned persistent header',
    );

    // The search field should respond to focus/tap (even inside the header).
    await tester.tap(searchInput());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(searchInput()).focusNode!.hasFocus, isTrue);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact sidebar scrolls fully without overflow '
      'in a small window', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    tester.view.physicalSize = const Size(900, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
    });

    await mount(tester, fx.repo, desktop: true);
    await tester.pumpAndSettle();
    expect(treeList(), findsOneWidget);

    // Verify the sidebar renders without RenderFlex overflow at 500px height.
    expect(tester.takeException(), isNull);

    // The tree list contains the expected folders.
    expect(
      find.descendant(of: treeList(), matching: find.text('Alpha')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: treeList(), matching: find.text('Root note')),
      findsNothing,
      reason: 'root is collapsed by default so root notes are hidden',
    );

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('normal mode toggle lives next to the search field '
      'in the notes list', (tester) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo, desktop: true);

    final toggleRect = tester.getRect(sidebarToggle());
    final searchRect = tester.getRect(searchField());

    // Same row: search field starts after the toggle padding area, but
    // their vertical centers should match.
    final toggleCenterY = toggleRect.center.dy;
    final searchCenterY = searchRect.center.dy;
    expect(
      toggleCenterY,
      closeTo(searchCenterY, 4),
      reason: 'the toggle and the search field share the same row',
    );

    // The toggle sits to the right of the search field.
    expect(
      toggleRect.left,
      greaterThan(searchRect.right - 10),
      reason: 'toggle is placed after the search field on the right',
    );

    // Tapping still collapses the notes list.
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);

    // Restore via the restore strip.
    expect(sidebarToggle(), findsOneWidget);
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsOneWidget);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact mode toggle hides the entire sidebar, '
      'restore button brings it back', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    expect(treeList(), findsOneWidget);
    expect(sidebarToggle(), findsOneWidget);

    // Record editor width with sidebar visible.
    final titleBefore = find.byKey(const Key('note-title'));
    // Open a note first so the editor pane has content.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(noteCard(fx.rootNote));
    await tester.pumpAndSettle();
    expect(titleBefore, findsOneWidget);
    final editorBefore = tester.getRect(titleBefore).left;

    // Hide the entire sidebar.
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();

    // The sidebar should be gone (or its tree invisible).
    expect(treeList(), findsNothing);
    final restoreBtn = find.byKey(const Key('sidebar-restore'));
    expect(restoreBtn, findsOneWidget);

    // Editor expanded into the freed width.
    final editorAfter = tester.getRect(titleBefore).left;
    expect(
      editorAfter,
      lessThan(editorBefore - 100),
      reason: 'editor moves left when the 300 px sidebar is hidden',
    );

    // Tap restore → sidebar returns.
    await tester.tap(restoreBtn);
    await tester.pumpAndSettle();
    expect(treeList(), findsOneWidget);
    expect(sidebarToggle(), findsOneWidget);
    expect(find.byKey(const Key('sidebar-restore')), findsNothing);
    final editorRestored = tester.getRect(titleBefore).left;
    expect(
      editorRestored,
      closeTo(editorBefore, 2),
      reason: 'editor returns to original position after restore',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // Coordinator addition (disclosed in reviews/round-0.2.38-state.md): the
  // worker card asserted only that a SliverPersistentHeader exists, which does
  // not prove the pinned behaviour.  This drives a real scroll and checks the
  // geometry: before the scroll the field sits under the SILIQUE header, after
  // the header scrolls away the field stays flush with the viewport top.
  testWidgets('search field pins to the top once the sidebar scrolls past it', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.pumpAndSettle();

    // Expand root and Alpha while the tall default surface still renders the
    // lazily-built sliver rows (they are unmounted when off-screen).
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();

    // mount() sets the surface size, so shrink the window afterwards to force
    // the sidebar content past its viewport and make it scrollable.
    tester.view.physicalSize = const Size(1200, 380);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpAndSettle();

    final viewportTop = tester.getRect(treeList()).top;
    final beforeTop = tester.getRect(searchField()).top;
    expect(
      beforeTop,
      greaterThan(viewportTop + 20),
      reason: 'before scrolling the field sits below the SILIQUE header',
    );

    final scrollable = find.descendant(
      of: treeList(),
      matching: find.byType(Scrollable),
    );
    final pos = tester.state<ScrollableState>(scrollable.first).position;
    // Drag repeatedly: one gesture may only move the content part-way, and the
    // field must still be pinned after the header has fully scrolled away.
    for (var i = 0; i < 6; i++) {
      await tester.drag(treeList(), const Offset(0, -200));
      await tester.pumpAndSettle();
    }
    expect(pos.pixels, greaterThan(0), reason: 'sidebar must have scrolled');
    expect(
      pos.pixels,
      greaterThan(300),
      reason: 'content long enough to scroll the header away',
    );

    final afterTop = tester.getRect(searchField()).top;
    expect(
      afterTop,
      closeTo(viewportTop, 2),
      reason: 'pinned field must sit flush with the viewport top after scroll',
    );
    // The field still accepts input while pinned.
    await tester.tap(searchInput());
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(searchInput()).focusNode!.hasFocus, isTrue);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // ── Consistency fixes (indent, icon+title, chevron, divider, hover) ──

  testWidgets('compact notes indent like the subfolders of their folder '
      'on desktop', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha/Beta'));
    await tester.pumpAndSettle();

    double left(Finder f) => tester.getTopLeft(f).dx;
    Finder iconIn(Finder f) =>
        find.descendant(of: f, matching: find.byType(Icon));
    Finder textIn(Finder f) =>
        find.descendant(of: f, matching: find.byType(Text));

    // Root notes (depth 0) sit 20 px right of a top-level folder row, so their
    // icon and title land in that folder's columns.
    expect(
      (left(noteCard(fx.rootNote)) - (left(folderRow('Alpha')) + 20)).abs(),
      lessThanOrEqualTo(1),
      reason: 'root note card must sit in the subfolder card column',
    );
    // A note inside Alpha (depth 0) aligns with Alpha's subfolder Beta
    // (depth 1) in every column.
    expect(
      (left(noteCard(fx.alphaNote)) - (left(folderRow('Alpha/Beta')) + 20))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note card must sit in the subfolder card column',
    );
    expect(
      (left(iconIn(noteCard(fx.alphaNote))) - left(folderIcon('Alpha/Beta')))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note icon must sit in the subfolder icon column',
    );
    expect(
      (left(textIn(noteCard(fx.alphaNote))) -
              left(textIn(folderRow('Alpha/Beta'))))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note title must sit in the subfolder title column',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact notes indent like the subfolders of their folder '
      'in the mobile drawer', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();

    final drawer = find.byType(Drawer);
    Finder inDrawer(Finder f) => find.descendant(of: drawer, matching: f);
    Finder iconIn(Finder f) =>
        find.descendant(of: f, matching: find.byType(Icon));
    Finder textIn(Finder f) =>
        find.descendant(of: f, matching: find.byType(Text));

    await tester.tap(inDrawer(find.byKey(const Key('compact-root-toggle'))));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(folderIcon('Alpha')));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(folderIcon('Alpha/Beta')));
    await tester.pumpAndSettle();

    double left(Finder f) => tester.getTopLeft(f).dx;

    expect(
      (left(inDrawer(noteCard(fx.rootNote))) -
              (left(inDrawer(folderRow('Alpha'))) + 20))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'root note card must sit in the subfolder card column',
    );
    expect(
      (left(inDrawer(noteCard(fx.alphaNote))) -
              (left(inDrawer(folderRow('Alpha/Beta'))) + 20))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note card must sit in the subfolder card column',
    );
    expect(
      (left(iconIn(inDrawer(noteCard(fx.alphaNote)))) -
              left(inDrawer(folderIcon('Alpha/Beta'))))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note icon must sit in the subfolder icon column',
    );
    expect(
      (left(textIn(inDrawer(noteCard(fx.alphaNote)))) -
              left(textIn(inDrawer(folderRow('Alpha/Beta')))))
          .abs(),
      lessThanOrEqualTo(1),
      reason: 'note title must sit in the subfolder title column',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact note row shows exactly one text: the title', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();

    final card = noteCard(fx.rootNote);
    expect(card, findsOneWidget);
    final texts = find.descendant(of: card, matching: find.byType(Text));
    expect(
      texts,
      findsOneWidget,
      reason: 'compact rows drop the snippet and time text',
    );
    expect(tester.widget<Text>(texts).data, 'Root note');

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('folders with only notes show a chevron and toggle them', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(treeText('Beta'), findsOneWidget);

    // Beta has a note but no subfolder — it must still expose a chevron.
    final betaToggle = find.byKey(const Key('folder-toggle-Alpha/Beta'));
    expect(betaToggle, findsOneWidget);
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: betaToggle, matching: find.byType(Icon)),
          )
          .icon,
      Icons.keyboard_arrow_right,
    );

    await tester.tap(betaToggle);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Icon>(
            find.descendant(of: betaToggle, matching: find.byType(Icon)),
          )
          .icon,
      Icons.keyboard_arrow_down,
    );
    expect(noteCard(fx.betaNote), findsOneWidget);

    await tester.tap(betaToggle);
    await tester.pumpAndSettle();
    expect(noteCard(fx.betaNote), findsNothing);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'root row shows a chevron for subfolders even without root notes',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('compact-root-chevron-');
      late Notebook repo;
      late String soloNoteId;
      await tester.runAsync(() async {
        repo = Notebook(
          storage: NativeStorage(dir.path),
          keys: MemoryKeys(),
          crypto: TestCrypto(),
        );
        await repo.initialize();
        await repo.createVault('Phone');
        final vault = repo.vaults.single;
        await repo.createFolder(vault, 'Solo');
        await repo.setCompactMode(vault, true);
        final note = await repo.createNote(vault.id, folder: 'Solo');
        await repo.save(note.copyWith(title: 'Solo note'));
        soloNoteId = note.id;
      });
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        final close = repo.close().then((_) => closed = true);
        await drainUntil(tester, () => closed);
        await close;
        await tester.runAsync(() async {
          dir.deleteSync(recursive: true);
        });
      });

      await mount(tester, repo, desktop: true);

      // No root note, but a root-level subfolder — the root toggle still shows.
      final rootToggle = find.byKey(const Key('compact-root-toggle'));
      expect(rootToggle, findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.descendant(of: rootToggle, matching: find.byType(Icon)),
            )
            .icon,
        Icons.keyboard_arrow_right,
      );
      expect(noteCard(soloNoteId), findsNothing);

      await tester.tap(rootToggle);
      await tester.pumpAndSettle();
      expect(treeText('Solo'), findsOneWidget);
      expect(noteCard(soloNoteId), findsNothing);

      await tester.tap(folderIcon('Solo'));
      await tester.pumpAndSettle();
      expect(noteCard(soloNoteId), findsOneWidget);

      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selected compact note matches the folder row surface', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();

    final card = noteCard(fx.rootNote);
    expect(card, findsOneWidget);

    Color titleColor() => tester
        .widget<Text>(find.descendant(of: card, matching: find.byType(Text)))
        .style!
        .color!;
    expect(titleColor(), const Color(0xffc0c7df));

    await tester.tap(card);
    await tester.pumpAndSettle();

    final noteMaterial = tester.widget<Material>(
      find.ancestor(of: card, matching: find.byType(Material)).first,
    );
    expect(noteMaterial.color, accent.withValues(alpha: .10));
    expect(titleColor(), Colors.white);

    final container = tester.widget<Container>(card);
    final border = (container.decoration! as BoxDecoration).border! as Border;
    for (final side in [border.top, border.bottom, border.left, border.right]) {
      expect(side.color, Colors.transparent);
    }

    final inkWell = tester.widget<InkWell>(
      find.ancestor(of: card, matching: find.byType(InkWell)).first,
    );
    expect(inkWell.hoverColor, isNull);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact multi-select highlights marked notes and keeps '
      'marked over selected', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    // Reveal the root, Alpha and Beta notes so all three are visible.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha/Beta'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);
    expect(noteCard(fx.betaNote), findsOneWidget);

    Future<void> ctrlTap(Finder finder) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.tap(finder);
      await tester.pumpAndSettle();
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }

    Color materialColor(Finder card) => tester
        .widget<Material>(
          find.ancestor(of: card, matching: find.byType(Material)).first,
        )
        .color!;

    Color borderColor(Finder card) {
      final container = tester.widget<Container>(card);
      final border = (container.decoration! as BoxDecoration).border! as Border;
      return border.top.color;
    }

    // Open Beta, then mark it: a note that is both selected and marked must
    // keep the marked surface (.16), never the selected one (.10).
    await tester.tap(noteCard(fx.betaNote));
    await tester.pumpAndSettle();
    await ctrlTap(noteCard(fx.betaNote));
    expect(materialColor(noteCard(fx.betaNote)), accent.withValues(alpha: .16));
    expect(borderColor(noteCard(fx.betaNote)), accent);

    // A second marked note also gets the accent surface and border.
    await ctrlTap(noteCard(fx.rootNote));
    expect(materialColor(noteCard(fx.rootNote)), accent.withValues(alpha: .16));
    expect(borderColor(noteCard(fx.rootNote)), accent);

    // The unmarked note stays fully transparent.
    expect(materialColor(noteCard(fx.alphaNote)), Colors.transparent);
    expect(borderColor(noteCard(fx.alphaNote)), Colors.transparent);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsed compact sidebar keeps its divider', (tester) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(find.byKey(const Key('sidebar-toggle-notes-list')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sidebar-restore')), findsOneWidget);
    final dividers = panelDividers();
    expect(dividers, findsOneWidget);
    final rail = tester.getRect(find.byKey(const Key('sidebar-restore')));
    final divider = tester.getRect(dividers);
    expect(divider.left, closeTo(rail.right, 1));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsed classic notes list keeps its divider', (tester) async {
    final fx = await treeFixture(tester);
    await mount(tester, fx.repo, desktop: true);
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();

    expect(sidebarToggle(), findsOneWidget);
    final dividers = panelDividers();
    expect(dividers, findsNWidgets(2));
    final rail = tester.getRect(sidebarToggle());

    // Exactly one divider is flush with the rail's right edge (notes↔editor).
    var adjacent = 0;
    for (var i = 0; i < 2; i++) {
      if ((tester.getRect(dividers.at(i)).left - rail.right).abs() <= 1) {
        adjacent++;
      }
    }
    expect(adjacent, 1);

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // ── Compact mode: folder creation must not leave the merged tree ──────

  testWidgets('creating a folder in compact mode keeps the tree and notes', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);
    final before = tester.widgetList(noteCards()).length;

    await tester.tap(find.byKey(const Key('new-root-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('folder-name')), 'Nowy');
    await tester.tap(find.byKey(const Key('folder-create')));
    await drainUntil(
      tester,
      () => fx.repo.allFolders(fx.repo.vaults.single.id).contains('Nowy'),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.byKey(const Key('compact-tree-list')),
      findsOneWidget,
      reason: 'creating a folder must not disable the compact tree',
    );
    expect(
      find.byKey(const Key('folder-row-Nowy')),
      findsOneWidget,
      reason: 'the new folder row appears in the compact tree',
    );
    expect(
      noteCard(fx.rootNote),
      findsOneWidget,
      reason: 'the root note stays visible',
    );
    expect(
      noteCard(fx.alphaNote),
      findsOneWidget,
      reason: 'the expanded Alpha note stays visible',
    );
    expect(
      tester.widgetList(noteCards()).length,
      before,
      reason: 'folder creation must not hide any visible note rows',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('creating a folder in the compact drawer keeps tree and notes', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo);
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();

    final drawer = find.byType(Drawer);
    Finder inDrawer(Finder f) => find.descendant(of: drawer, matching: f);

    await tester.tap(inDrawer(find.byKey(const Key('compact-root-toggle'))));
    await tester.pumpAndSettle();
    await tester.tap(inDrawer(folderIcon('Alpha')));
    await tester.pumpAndSettle();
    expect(inDrawer(noteCard(fx.rootNote)), findsOneWidget);
    expect(inDrawer(noteCard(fx.alphaNote)), findsOneWidget);
    final before = tester.widgetList(inDrawer(noteCards())).length;

    await tester.tap(inDrawer(find.byKey(const Key('new-root-folder'))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('folder-name')), 'Nowy');
    await tester.tap(find.byKey(const Key('folder-create')));
    await drainUntil(
      tester,
      () => fx.repo.allFolders(fx.repo.vaults.single.id).contains('Nowy'),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(
      inDrawer(find.byKey(const Key('compact-tree-list'))),
      findsOneWidget,
      reason: 'creating a folder must not disable the compact drawer tree',
    );
    expect(
      inDrawer(find.byKey(const Key('folder-row-Nowy'))),
      findsOneWidget,
      reason: 'the new folder row appears in the drawer tree',
    );
    expect(
      inDrawer(noteCard(fx.rootNote)),
      findsOneWidget,
      reason: 'the root note stays visible in the drawer',
    );
    expect(
      inDrawer(noteCard(fx.alphaNote)),
      findsOneWidget,
      reason: 'the expanded Alpha note stays visible in the drawer',
    );
    expect(
      tester.widgetList(inDrawer(noteCards())).length,
      before,
      reason: 'folder creation must not hide any visible note rows',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('creating a subfolder in compact mode expands its ancestors', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.alphaNote), findsOneWidget);

    await tester.tap(find.byKey(const Key('folder-menu-Alpha')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nowy podfolder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('folder-name')), 'Pod');
    await tester.tap(find.byKey(const Key('folder-create')));
    await drainUntil(
      tester,
      () => fx.repo.allFolders(fx.repo.vaults.single.id).contains('Alpha/Pod'),
    );
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.byKey(const Key('folder-row-Alpha/Pod')),
      findsOneWidget,
      reason: 'the new subfolder row appears with its ancestor expanded',
    );
    expect(
      find.byKey(const Key('compact-tree-list')),
      findsOneWidget,
      reason: 'creating a subfolder must not disable the compact tree',
    );
    expect(
      noteCard(fx.alphaNote),
      findsOneWidget,
      reason: 'the parent folder note stays visible',
    );

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  // ── compact multi-select entry point & selection bar ──────────────────

  testWidgets('compact-select-mode sits flush right and vertically aligned', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);
    final button = find.byKey(const Key('compact-select-mode'));
    expect(button, findsOneWidget);

    final sidebarRect = tester.getRect(treeList());
    final buttonRect = tester.getRect(button);
    // Right edge ≤ 1px from the sidebar right edge minus 13.
    expect(
      (sidebarRect.right - 13) - buttonRect.right,
      lessThanOrEqualTo(1),
      reason: 'compact-select-mode flush with the 13px sidebar inset',
    );
    // Vertically centered with the Ulubione chip.
    final ulubione = tester.getRect(
      find.byKey(const Key('compact-filter-Ulubione')),
    );
    expect(
      (buttonRect.center.dy - ulubione.center.dy).abs(),
      lessThanOrEqualTo(1),
      reason: 'compact-select-mode shares the filter row centre line',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('compact-select-mode toggles selection and the sidebar bar', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    // Reveal root and Alpha notes.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(folderIcon('Alpha'));
    await tester.pumpAndSettle();
    expect(noteCard(fx.rootNote), findsOneWidget);
    expect(noteCard(fx.alphaNote), findsOneWidget);

    // Enter select mode.
    await tester.tap(find.byKey(const Key('compact-select-mode')));
    await tester.pumpAndSettle();

    // Radio circles appear on the note cards.
    expect(
      find.descendant(
        of: noteCard(fx.rootNote),
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('selection-bar')),
      findsOneWidget,
      reason: 'selection bar appears in the compact sidebar',
    );

    // Tapping a note selects rather than opens it.
    await tester.tap(noteCard(fx.rootNote));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const Key('selection-count'))).data,
      contains('1'),
    );

    // Second tap exits select mode and clears selection.
    await tester.tap(find.byKey(const Key('compact-select-mode')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('selection-bar')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('single click expands a folder while the editor has focus', (
    tester,
  ) async {
    final fx = await treeFixture(tester, compact: true);
    await mount(tester, fx.repo, desktop: true);

    // Reveal and open the root note so the editor exists and holds focus.
    await tester.tap(find.byKey(const Key('compact-root-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(noteCard(fx.rootNote));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-title')), findsOneWidget);

    // Give the title field keyboard focus.
    await tester.tap(find.byKey(const Key('note-title')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(titleField()).focusNode!.hasFocus,
      isTrue,
    );

    // A single mouse click must expand it. A real click on Linux moves the
    // pointer by a fraction of a pixel between press and release, which the
    // immediate `Draggable` used to win as a drag — the tap never fired.
    final click = await tester.startGesture(
      tester.getCenter(folderRow('Alpha')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump(const Duration(milliseconds: 16));
    await click.moveBy(const Offset(1.5, 0.5));
    await tester.pump(const Duration(milliseconds: 16));
    await click.up();
    await tester.pumpAndSettle();

    final chevron = find.descendant(
      of: folderRow('Alpha'),
      matching: find.byType(Icon),
    );
    expect(
      tester.widgetList(chevron).any(
        (w) => (w as Icon).icon == Icons.keyboard_arrow_down,
      ),
      isTrue,
      reason: 'one click expands Alpha even with editor focus',
    );
    expect(
      noteCard(fx.alphaNote),
      findsOneWidget,
      reason: 'Alpha notes appear after the single click',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
