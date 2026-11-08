import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

ScrollController documentScroll(WidgetTester tester) => tester
    .widget<SingleChildScrollView>(find.byKey(const Key('mobile-note-scroll')))
    .controller!;

Rect caretRect(EditableTextState state) {
  final render = state.renderEditable;
  return render
      .getLocalRectForCaret(
        TextPosition(offset: state.widget.controller.selection.extentOffset),
      )
      .shift(render.localToGlobal(Offset.zero));
}

void expectVisibleCaret(WidgetTester tester, EditableTextState state) {
  final viewport = tester.getRect(find.byKey(const Key('mobile-note-scroll')));
  final keyboardTop =
      tester.view.physicalSize.height / tester.view.devicePixelRatio -
      tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
  final visible = viewport.intersect(Rect.fromLTRB(0, 0, 390, keyboardTop));
  final caret = caretRect(state);
  expect(caret.top, greaterThanOrEqualTo(visible.top));
  expect(caret.bottom, lessThanOrEqualTo(visible.bottom));
  expect(caret.center.dx, inInclusiveRange(visible.left, visible.right));
}

void main() {
  for (final source in [false, true]) {
    testWidgets(
      'Android soft keyboard preserves mid-note focus connection and visible caret source=$source',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
        });
        final repo = await openPhone(tester, long: true);
        if (source) {
          await tester.ensureVisible(
            find.byTooltip('Markdown / podgląd na żywo'),
          );
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final field = find.byKey(
          source
              ? const Key('source-editor')
              : const ValueKey('livemd-document-field'),
        );
        final editable = find.descendant(
          of: field,
          matching: find.byType(EditableText),
        );
        await tester.tapAt(const Offset(110, 400));
        await tester.pumpAndSettle();
        final state = tester.state<EditableTextState>(editable);
        final controller = state.widget.controller;
        final focus = state.widget.focusNode;
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        final connection = tester.testTextInput.log
            .lastWhere((call) => call.method == 'TextInput.setClient')
            .arguments[0];
        final connectionLogStart = tester.testTextInput.log.length;

        void expectSameInput() {
          expect(tester.state<EditableTextState>(editable), same(state));
          expect(state.widget.controller, same(controller));
          expect(state.widget.focusNode, same(focus));
          expect(focus.hasFocus, isTrue);
          expect(tester.testTextInput.hasAnyClients, isTrue);
          expect(
            tester.testTextInput.log
                .lastWhere((call) => call.method == 'TextInput.setClient')
                .arguments[0],
            connection,
          );
          expect(
            tester.testTextInput.log
                .skip(connectionLogStart)
                .where(
                  (call) =>
                      call.method == 'TextInput.setClient' ||
                      call.method == 'TextInput.clearClient',
                ),
            isEmpty,
          );
        }

        // Keyboard metrics must not replace the focused editable or its client.
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        expectSameInput();
        final scroll = documentScroll(tester);
        await tester.dragFrom(const Offset(195, 440), const Offset(0, -1000));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(110, 360));
        await tester.pumpAndSettle();
        expectSameInput();
        final anchor = scroll.offset;
        final insertion = controller.selection.extentOffset;
        final original = controller.text;
        expect(anchor, greaterThan(500));
        expect(insertion, inExclusiveRange(0, original.length));
        expectVisibleCaret(tester, state);

        // Send platform text-input messages, not controller assignments or
        // tester.enterText (which would request focus again and hide a failure).
        var inserted = '';
        for (final ch in 'ABC'.split('')) {
          inserted += ch;
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: original.replaceRange(insertion, insertion, inserted),
              selection: TextSelection.collapsed(
                offset: insertion + inserted.length,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 60));
          expectSameInput();
          expect(
            controller.text,
            original.replaceRange(insertion, insertion, inserted),
          );
          expect(
            controller.selection,
            TextSelection.collapsed(offset: insertion + inserted.length),
          );
          expect(
            scroll.offset,
            closeTo(anchor, 1),
            reason: 'Typing must not reset the document to its head',
          );
          expectVisibleCaret(tester, state);
        }
        // Include the delayed save/rebuild and caret-reveal callbacks.
        await tester.pump(const Duration(seconds: 2));
        // Alternate real I/O and fake-zone microtasks; awaiting the queue
        // entirely in runAsync deadlocks continuations registered by autosave
        // in the test zone. Bound the loop so a failed save fails promptly.
        final savedBody = original.replaceRange(insertion, insertion, 'ABC');
        for (
          var i = 0;
          i < 50 &&
              repo.notes[repo.vaults.single.id]!.values.single.body !=
                  savedBody;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(
          repo.notes[repo.vaults.single.id]!.values.single.body,
          savedBody,
        );
        expectSameInput();
        expect(
          controller.text,
          original.replaceRange(insertion, insertion, 'ABC'),
        );
        expect(
          controller.selection,
          TextSelection.collapsed(offset: insertion + 3),
        );
        expect(scroll.offset, closeTo(anchor, 1));
        expectVisibleCaret(tester, state);

        // Growing beyond the keyboard-shortened viewport must reveal the new
        // caret without replacing the input client or snapping to the title.
        final beforeGrowth = scroll.offset;
        final growth = List.filled(24, '\nnew keyboard line').join();
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: controller.text.replaceRange(
              insertion + 3,
              insertion + 3,
              growth,
            ),
            selection: TextSelection.collapsed(
              offset: insertion + 3 + growth.length,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expectSameInput();
        expect(
          controller.selection.extentOffset,
          insertion + 3 + growth.length,
        );
        expect(scroll.offset, greaterThan(beforeGrowth));
        expectVisibleCaret(tester, state);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
