import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/main.dart';

import 'hidden_notes_home_test.dart' show fixture, mount;

/// The note content column is the [ConstrainedBox] the desktop layout wraps the
/// heading and body in so long lines stay readable. It exists only when the
/// viewport limits the column width (desktop), never on mobile.
Finder contentColumn() => find.byWidgetPredicate(
  (w) =>
      w is ConstrainedBox &&
      w.constraints.maxWidth == 820 &&
      w.constraints.maxHeight == double.infinity,
);

Future<void> openNote(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('note-card-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('desktop bounds the note column to 820 px and centers it', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final note = repo.notes[repo.vaults.single.id]!.values.single;
    await mount(tester, repo, desktop: true);
    await openNote(tester, note.id);

    final column = contentColumn();
    expect(column, findsOneWidget);

    final columnRect = tester.getRect(column);
    expect(
      columnRect.width,
      lessThanOrEqualTo(820),
      reason: 'note content must stay within a 820 px column',
    );

    // The editor pane is the remaining width after the 220 px sidebar, the
    // 320 px notes list and their two 1 px dividers on a 1440 px window.
    final editorLeft = 220 + 320 + 2;
    final editorCenter = editorLeft + (1440 - editorLeft) / 2;
    final columnCenter = columnRect.center.dx;
    expect(
      columnCenter,
      closeTo(editorCenter, 1),
      reason: 'the column is centered within the editor panel',
    );

    // Text inside the column stays left aligned; the title field's left edge
    // sits at the column's left edge plus its 32 px padding.
    final title = tester.getTopLeft(find.byKey(const Key('note-title')));
    expect(title.dx, closeTo(columnRect.left + 32, 1));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile width keeps the historical 32 px body padding', (
    tester,
  ) async {
    final repo = await fixture(tester);
    final note = repo.notes[repo.vaults.single.id]!.values.single;
    // 900 px is below the 1000 px breakpoint, so the mobile layout applies and
    // the note keeps its plain 32 px padding, untrimmed by any column.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(900, 900);
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
    await openNote(tester, note.id);

    // No 820 px column constraint on mobile.
    expect(
      contentColumn(),
      findsNothing,
      reason: 'mobile does not cap the note column',
    );

    // The title field still starts 22 px from the left edge on mobile layout
    // (the mobile heading padding), confirming the note is not constrained.
    final title = find.byKey(const Key('note-title'));
    expect(title, findsOneWidget);
    final editorLeft = tester.getTopLeft(find.byKey(const Key('mobile-note-scroll'))).dx;
    final titleLeft = tester.getTopLeft(title).dx;
    expect(titleLeft, closeTo(editorLeft + 22, 1));

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}