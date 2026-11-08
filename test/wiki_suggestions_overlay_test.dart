import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/services/notebook.dart';
import 'package:silique/ui/menus.dart';

import 'hidden_notes_home_test.dart' show fixture, mount;

Finder panel() => find.byKey(const Key('wiki-suggestions'));

Finder documentViewport() => find.byKey(const Key('mobile-note-scroll'));

Finder bodyField(bool source) => source
    ? find.byKey(const Key('source-editor'))
    : find.byKey(const ValueKey('livemd-document-field'));

EditableTextState bodyState(WidgetTester tester, bool source) => tester
    .state<EditableTextState>(
      find
          .descendant(of: bodyField(source), matching: find.byType(EditableText))
          .first,
    );

ScrollController documentScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(documentViewport())
    .controller!;

/// The caret rectangle in global coordinates, taken straight from the laid
/// out editable: the same geometry the floating panel anchors to.
Rect caretGlobal(EditableTextState state) {
  final render = state.renderEditable;
  return render
      .getLocalRectForCaret(
        TextPosition(offset: state.widget.controller.selection.extentOffset),
      )
      .shift(render.localToGlobal(Offset.zero));
}

/// Adds the wiki link target. The target is saved last, so the home screen
/// opens it first and the test selects the fixture note from the list. With
/// [longBody] the fixture note becomes a document long enough to scroll.
Future<void> seedNotes(
  WidgetTester tester,
  Notebook repo, {
  bool longBody = false,
}) async {
  await tester.runAsync(() async {
    final vaultId = repo.vaults.single.id;
    if (longBody) {
      final note = repo.notes[vaultId]!.values.firstWhere(
        (n) => n.title == 'Visible secret',
      );
      await repo.save(
        note.copyWith(
          body: List.generate(140, (i) => 'Wiersz $i dokumentu').join('\n'),
        ),
      );
    }
    final target = await repo.createNote(vaultId);
    await repo.save(target.copyWith(title: 'Mercaro – pomysły', body: 'Cel'));
  });
}

Future<void> openFixtureNote(
  WidgetTester tester,
  Notebook repo,
  bool source,
) async {
  final note = repo.notes[repo.vaults.single.id]!.values.firstWhere(
    (n) => n.title == 'Visible secret',
  );
  await tester.tap(find.byKey(Key('note-card-${note.id}')));
  await tester.pumpAndSettle();
  if (source) {
    final toggle = find.byTooltip('Markdown / podgląd na żywo');
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final source in [false, true]) {
    testWidgets(
      'wiki suggestions float at the caret without moving the document source=$source',
      (tester) async {
        final repo = await fixture(tester);
        await seedNotes(tester, repo);
        await mount(tester, repo, desktop: true);
        await openFixtureNote(tester, repo, source);
        final field = bodyField(source);
        await tester.enterText(field, 'Zobacz ');
        await tester.pumpAndSettle();
        expect(panel(), findsNothing);
        // Floating proof: the editor field rectangle and the document scroll
        // offset must be identical before and after the panel appears. The
        // former in-column list shifted the whole editor down by 100 px.
        final rectBefore = tester.getRect(field);
        final scrollBefore = documentScroll(tester).offset;
        await tester.enterText(field, 'Zobacz [[');
        await tester.pumpAndSettle();
        expect(panel(), findsOneWidget);
        expect(tester.getRect(field), rectBefore);
        expect(documentScroll(tester).offset, scrollBefore);
        // With room below, the panel opens right under the caret.
        final state = bodyState(tester, source);
        final caret = caretGlobal(state);
        final panelRect = tester.getRect(panel());
        expect(panelRect.top - caret.bottom, closeTo(6, 1));
        expect(panelRect.left, closeTo(caret.left, 1));
        // Tapping a suggestion completes the link, hides the panel and keeps
        // the focus in the document field (menu rows never request focus).
        await tester.tap(
          find.widgetWithText(SiliqueMenuRow, 'Mercaro – pomysły'),
        );
        await tester.pumpAndSettle();
        expect(state.widget.controller.text, 'Zobacz [[Mercaro – pomysły]]');
        expect(panel(), findsNothing);
        expect(state.widget.focusNode.hasFocus, isTrue);
        // Hiding the panel must not move the document either.
        expect(tester.getRect(field), rectBefore);
        // Flush the debounced autosave so no timer outlives the widget tree.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final source in [false, true]) {
    testWidgets(
      'near the bottom edge the wiki panel opens above the caret source=$source',
      (tester) async {
        final repo = await fixture(tester);
        await seedNotes(tester, repo, longBody: true);
        await mount(tester, repo, desktop: true);
        await openFixtureNote(tester, repo, source);
        // Put the caret on the last visible line, close to the bottom edge
        // of the document stack, through the real tap and input paths.
        final scroll = documentScroll(tester);
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final viewport = tester.getRect(documentViewport());
        // Tap the actual last rendered glyph instead of a fixed offset from
        // the viewport bottom: the live editor's 36px bottom padding swallows
        // raw taps below its text, so the fixed point never focused the field
        // in live mode.
        final state = bodyState(tester, source);
        final lastOffset = state.widget.controller.text.length;
        final glyph = state.renderEditable
            .getBoxesForSelection(
              TextSelection(
                baseOffset: (lastOffset - 1).clamp(0, lastOffset),
                extentOffset: lastOffset,
              ),
            )
            .last
            .toRect()
            .shift(state.renderEditable.localToGlobal(Offset.zero))
            .center;
        await tester.tapAt(glyph);
        await tester.pumpAndSettle();
        expect(state.widget.focusNode.hasFocus, isTrue);
        final controller = state.widget.controller;
        final insertion = controller.selection.extentOffset;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: controller.text.replaceRange(insertion, insertion, '[['),
            selection: TextSelection.collapsed(offset: insertion + 2),
          ),
        );
        await tester.pumpAndSettle();
        expect(panel(), findsOneWidget);
        final caret = caretGlobal(state);
        expect(
          caret.top,
          greaterThan(viewport.bottom - 120),
          reason: 'the flip scenario requires a caret low in the viewport',
        );
        final panelRect = tester.getRect(panel());
        expect(
          panelRect.top,
          lessThan(caret.top),
          reason: 'with no room below, the panel renders above the caret',
        );
        expect(panelRect.bottom, lessThanOrEqualTo(caret.top));
        // Flush the debounced autosave so no timer outlives the widget tree.
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
