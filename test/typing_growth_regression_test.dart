import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

// Keep lookup compatible with the released NestedScrollView layout. Running
// this exact regression against 0.2.12 must fail on behavior, not a missing key.
Finder documentViewport() {
  final single = find.byKey(const Key('mobile-note-scroll'));
  return single.evaluate().isNotEmpty ? single : find.byType(NestedScrollView);
}

ScrollController documentScroll(WidgetTester tester) {
  final single = find.byKey(const Key('mobile-note-scroll'));
  if (single.evaluate().isNotEmpty) {
    return tester.widget<SingleChildScrollView>(single).controller!;
  }
  return tester
      .widget<TextField>(find.byKey(const ValueKey('livemd-document-field')))
      .scrollController!;
}

void expectVisibleCaret(WidgetTester tester, EditableTextState state) {
  final viewport = tester.getRect(documentViewport());
  final keyboardTop =
      tester.view.physicalSize.height / tester.view.devicePixelRatio -
      tester.view.viewInsets.bottom / tester.view.devicePixelRatio;
  final visible = viewport.intersect(Rect.fromLTRB(0, 0, 390, keyboardTop));
  final render = state.renderEditable;
  final caret = render
      .getLocalRectForCaret(
        TextPosition(offset: state.widget.controller.selection.extentOffset),
      )
      .shift(render.localToGlobal(Offset.zero));
  expect(caret.top, greaterThanOrEqualTo(visible.top));
  expect(caret.bottom, lessThanOrEqualTo(visible.bottom));
  expect(caret.center.dx, inInclusiveRange(visible.left, visible.right));
}

void main() {
  for (final lines in [1, 24]) {
    testWidgets(
      'live Android IME newline growth retains scrolled document lines=$lines',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.view.resetViewInsets();
        });
        await openPhone(tester, long: true);
        final editable = find.descendant(
          of: find.byKey(const ValueKey('livemd-document-field')),
          matching: find.byType(EditableText),
        );
        await tester.tapAt(const Offset(110, 400));
        await tester.pumpAndSettle();
        final state = tester.state<EditableTextState>(editable);
        final controller = state.widget.controller;
        final focus = state.widget.focusNode;
        final connection = tester.testTextInput.log
            .lastWhere((c) => c.method == 'TextInput.setClient')
            .arguments[0];
        final logStart = tester.testTextInput.log.length;
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        final scroll = documentScroll(tester);
        await tester.dragFrom(const Offset(195, 440), const Offset(0, -1000));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(110, 360));
        await tester.pumpAndSettle();
        final before = scroll.offset;
        expect(before, greaterThan(500));
        expectVisibleCaret(tester, state);
        final insertion = controller.selection.extentOffset;
        final original = controller.text;
        final growth = List.filled(lines, '\nnew keyboard line').join();
        final expected = original.replaceRange(insertion, insertion, growth);
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: expected,
            selection: TextSelection.collapsed(
              offset: insertion + growth.length,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.state<EditableTextState>(editable), same(state));
        expect(state.widget.controller, same(controller));
        expect(state.widget.focusNode, same(focus));
        expect(focus.hasFocus, isTrue);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        expect(
          tester.testTextInput.log
              .lastWhere((c) => c.method == 'TextInput.setClient')
              .arguments[0],
          connection,
        );
        expect(
          tester.testTextInput.log
              .skip(logStart)
              .where(
                (c) =>
                    c.method == 'TextInput.setClient' ||
                    c.method == 'TextInput.clearClient',
              ),
          isEmpty,
        );
        expect(controller.text, expected);
        expect(
          controller.selection,
          TextSelection.collapsed(offset: insertion + growth.length),
        );
        expect(
          scroll.offset,
          greaterThanOrEqualTo(before),
          reason: 'IME growth must not snap the scrolled document to its head',
        );
        expectVisibleCaret(tester, state);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
