import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';

import 'hidden_notes_home_test.dart' show fixture, mount;

Finder searchField() => find.byKey(const Key('note-search-field'));

Finder sidebarHeader() => find.text('FOLDERY');

Finder titleField() => find.byKey(const Key('note-title'));

Finder sidebarToggle() => find.byKey(const Key('sidebar-toggle-notes-list'));

Finder oldCollapseInFilterRow() =>
    find.byKey(const Key('collapse-notes-list'));

Finder oldToggleInTabBar() => find.byKey(const Key('toggle-notes-list'));

Future<void> openNote(WidgetTester tester, Notebook repo) async {
  final note = repo.notes[repo.vaults.single.id]!.values.single;
  await tester.tap(find.byKey(Key('note-card-${note.id}')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('sidebar header toggle collapses and restores the notes list', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    await openNote(tester, repo);
    final note = repo.notes[repo.vaults.single.id]!.values.single;
    expect(searchField(), findsOneWidget);
    expect(sidebarToggle(), findsOneWidget);
    expect(oldCollapseInFilterRow(), findsNothing);
    expect(oldToggleInTabBar(), findsNothing);
    final before = tester.getTopLeft(titleField()).dx;
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);
    expect(
      find.byKey(Key('note-card-${note.id}')),
      findsNothing,
      reason: 'the notes list panel is removed together with its divider',
    );
    expect(sidebarHeader(), findsOneWidget);
    expect(
      sidebarToggle(),
      findsOneWidget,
      reason: 'the sidebar toggle stays reachable while the list is hidden',
    );
    expect(
      tester.getTopLeft(titleField()).dx - before,
      closeTo(-281, 1),
      reason: 'the editor takes over the collapsed panel minus the restore strip (320 px + divider - 40 px)',
    );
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsOneWidget);
    expect(find.byKey(Key('note-card-${note.id}')), findsOneWidget);
    expect(
      tester.widget<TextField>(titleField()).controller!.text,
      note.title,
      reason: 'the previously selected note stays open in the editor',
    );
    expect(tester.getTopLeft(titleField()).dx, closeTo(before, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('collapsing from the sidebar header keeps the open note', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    await openNote(tester, repo);
    final note = repo.notes[repo.vaults.single.id]!.values.single;
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);
    expect(find.byKey(Key('note-card-${note.id}')), findsNothing);
    expect(sidebarHeader(), findsOneWidget);
    expect(
      tester.widget<TextField>(titleField()).controller!.text,
      note.title,
      reason: 'collapsing keeps the open note and its editor state',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile keeps the list as before and its drawer has no toggle', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo);
    expect(searchField(), findsOneWidget);
    expect(sidebarToggle(), findsNothing);
    expect(oldCollapseInFilterRow(), findsNothing);
    expect(oldToggleInTabBar(), findsNothing);

    // The drawer renders the same sidebar in its mobile variant, without
    // the collapse control.
    await tester.tap(find.byTooltip('Foldery i vaulty'));
    await tester.pumpAndSettle();
    expect(sidebarHeader(), findsOneWidget);
    expect(
      sidebarToggle(),
      findsNothing,
      reason: 'the mobile drawer sidebar never shows the collapse toggle',
    );
    tester.state<ScaffoldState>(find.byType(Scaffold).first).closeDrawer();
    await tester.pumpAndSettle();

    await openNote(tester, repo);
    expect(titleField(), findsOneWidget);
    expect(sidebarToggle(), findsNothing);
    expect(oldCollapseInFilterRow(), findsNothing);
    expect(oldToggleInTabBar(), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('focus mode exit keeps the collapsed notes list', (
    tester,
  ) async {
    final repo = await fixture(tester);
    await mount(tester, repo, desktop: true);
    await openNote(tester, repo);
    await tester.tap(sidebarToggle());
    await tester.pumpAndSettle();
    expect(searchField(), findsNothing);
    await tester.tap(find.byTooltip('Tryb skupienia'));
    await tester.pumpAndSettle();
    expect(sidebarHeader(), findsNothing);
    expect(
      sidebarToggle(),
      findsNothing,
      reason: 'the whole sidebar, toggle included, is hidden in focus mode',
    );
    await tester.tap(find.byTooltip('Tryb skupienia'));
    await tester.pumpAndSettle();
    expect(sidebarHeader(), findsOneWidget);
    expect(
      searchField(),
      findsNothing,
      reason: 'the list stays collapsed after leaving focus mode',
    );
    expect(sidebarToggle(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
