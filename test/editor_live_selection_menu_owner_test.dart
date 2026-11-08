import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/menus.dart';

import 'hidden_notes_home_test.dart' show fixture, mount;

/// Owner report 2026-11-04: after selecting text with the mouse in the note
/// editor, the context menu shows a single visible entry ("Cofnij"). The menu
/// card was one row tall: the remaining edit commands were not rendered at
/// all. The full edit menu (undo/redo/cut/copy/paste/delete/select-all) must
/// be fully VISIBLE and tappable for a real drag selection, in both editor
/// modes and on every desktop platform.
void main() {
  for (final source in [false, true]) {
    testWidgets(
      'real drag selection in the ${source ? 'source field' : 'live document'} '
      'opens the full selection menu with every row visible and tappable',
      (tester) async {
        final repo = await fixture(tester);
        await mount(tester, repo, desktop: true);
        final id = repo.notes[repo.vaults.single.id]!.values.single.id;
        await tester.tap(find.byKey(Key('note-card-$id')));
        await tester.pumpAndSettle();
        final document = tester
            .widget<LiveMarkdownEditor>(find.byType(LiveMarkdownEditor))
            .controller;
        if (source) {
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final body = source
            ? find.byKey(const Key('source-editor'))
            : find.byType(LiveMarkdownEditor);
        final finder = find
            .descendant(of: body, matching: find.byType(EditableText))
            .first;
        await tester.tapAt(tester.getTopLeft(finder) + const Offset(8, 8));
        await tester.pumpAndSettle();
        final editable = tester.state<EditableTextState>(finder);
        final original = document.text;
        final selection = const TextSelection(baseOffset: 0, extentOffset: 8);
        final boxes = editable.renderEditable.getBoxesForSelection(selection);
        expect(boxes, isNotEmpty);
        final start = editable.renderEditable.localToGlobal(
          Offset(boxes.first.toRect().left, boxes.first.toRect().center.dy),
        );
        final end = editable.renderEditable.localToGlobal(
          Offset(boxes.last.toRect().right, boxes.last.toRect().center.dy),
        );
        final gesture = await tester.startGesture(
          start,
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveTo(end);
        await tester.pump(const Duration(milliseconds: 60));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(
          editable.textEditingValue.selection.isCollapsed,
          isFalse,
          reason: 'the drag selection must survive until the menu opens',
        );
        await tester.tapAt(
          editable.renderEditable.localToGlobal(boxes.first.toRect().center),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        final toolbar = find.byType(SiliqueSelectionToolbar);
        expect(toolbar, findsOneWidget);
        final menu = tester.widget<SiliqueSelectionToolbar>(toolbar);
        expect(menu.buttonItems.length, 7);
        expect(
          menu.buttonItems.map((item) => item.label ?? item.type.name).toList(),
          ['Cofnij', 'Ponów', 'cut', 'copy', 'paste', 'Usuń', 'selectAll'],
        );
        final enabled = menu.buttonItems
            .map((item) => item.onPressed != null)
            .toList();
        expect(enabled[2], isTrue, reason: 'cut enabled on a real selection');
        expect(enabled[3], isTrue, reason: 'copy enabled on a real selection');
        expect(
          enabled[5],
          isTrue,
          reason: 'delete enabled on a real selection',
        );
        expect(
          enabled[6],
          isTrue,
          reason: 'select-all enabled while a partial range is selected',
        );
        // Every row must be painted inside the visible menu card, not clipped
        // to the first row (the owner's screenshot showed a one-row card).
        final card = tester.getRect(find.byType(SiliqueMenuSurface));
        final rows = find.descendant(
          of: toolbar,
          matching: find.byType(SiliqueMenuRow),
        );
        expect(rows, findsNWidgets(7));
        for (final element in rows.evaluate()) {
          final render = element.renderObject! as RenderBox;
          expect(render.attached, isTrue);
          final row = render.localToGlobal(Offset.zero) & render.size;
          expect(
            card.contains(row.topLeft) && card.contains(row.bottomRight),
            isTrue,
            reason: 'row $row must be fully visible inside the card $card',
          );
        }
        // The delete row must be reachable through a real hit test.
        await tester.tap(rows.at(5));
        await tester.pumpAndSettle();
        expect(document.text, original.substring(8));
        expect(toolbar, findsNothing);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );
  }
}
