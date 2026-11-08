import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/mobile_note_viewport.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

void main() {
  for (final hitOffset in const [Offset(-1, 1), Offset(-30, 10)]) {
    testWidgets(
      'phone live start handle keeps extending upward at the viewport edge hit=$hitOffset',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.reset);
        final text = List.generate(
          100,
          (i) => 'Line $i words for selection with more text',
        ).join('\n');
        final document = LiveMarkdownController(text: text);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: Scaffold(
              appBar: AppBar(title: const Text('Editor')),
              body: MobileNoteViewport(
                heading: const SizedBox(height: 160),
                bodyBuilder: (scroll) => LiveMarkdownEditor(
                  controller: document,
                  scrollController: scroll,
                  contentSizedField: true,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final viewport = find.byKey(const Key('mobile-note-scroll'));
        final scroll = tester
            .widget<SingleChildScrollView>(viewport)
            .controller!;
        scroll.jumpTo(900);
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('livemd-document-field'));
        final editing = tester.widget<TextField>(field).controller!;
        final state = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        final longPress = await tester.startGesture(const Offset(240, 380));
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        await longPress.up();
        await tester.pumpAndSettle();
        expect(editing.selection.isCollapsed, isFalse);
        final anchor = editing.selection.end;
        final endpoints = state.renderEditable.getEndpointsForSelection(
          editing.selection,
        );
        final handle =
            state.renderEditable.localToGlobal(endpoints.first.point) +
            hitOffset;
        final gesture = await tester.startGesture(handle);
        await tester.pump();
        await gesture.moveBy(const Offset(0, -30));
        await tester.pump();
        await gesture.moveTo(Offset(110, tester.getRect(viewport).top + 4));
        await tester.pump(const Duration(milliseconds: 100));
        final offset = scroll.offset;
        final selection = editing.selection;
        expect(
          selection.start,
          lessThan(anchor - 20),
          reason: 'The real native handle, not the text field, must receive the drag',
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        debugPrint(
          'HANDLE up: $offset -> ${scroll.offset}, $selection -> ${editing.selection}',
        );
        expect(
          scroll.offset,
          lessThan(offset),
          reason:
              'A stationary upper handle must keep edge-scrolling the document',
        );
        expect(editing.selection.start, lessThan(selection.start));
        expect(
          editing.selection.end,
          anchor,
          reason: 'Dragging the upper handle must not move the lower anchor',
        );
        expect(document.text, text);
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 200));
        final stopped = scroll.offset;
        await tester.pump(const Duration(seconds: 1));
        expect(scroll.offset, stopped);
        expect(
          identical(
            state,
            tester.state<EditableTextState>(find.byType(EditableText)),
          ),
          isTrue,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        document.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final live in [true, false]) {
    for (final upwards in [true, false]) {
      testWidgets(
        'HomeScreen ${live ? 'live' : 'source'} native ${upwards ? 'start' : 'end'} handle scrolls monotonically with keyboard',
        (tester) async {
          await openPhone(tester, long: true);
          if (!live) {
            await tester.ensureVisible(
              find.byTooltip('Markdown / podgląd na żywo'),
            );
            await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
            await tester.pumpAndSettle();
          }
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          final viewport = find.byKey(const Key('mobile-note-scroll'));
          final scroll = tester
              .widget<SingleChildScrollView>(viewport)
              .controller!;
          scroll.jumpTo(900);
          await tester.pumpAndSettle();
          final field = find.byKey(
            ValueKey(live ? 'livemd-document-field' : 'source-editor'),
          );
          final editing = tester.widget<TextField>(field).controller!;
          final state = tester.state<EditableTextState>(
            find.descendant(of: field, matching: find.byType(EditableText)),
          );
          final rect = tester.getRect(viewport);
          final press = await tester.startGesture(Offset(110, rect.center.dy));
          await tester.pump(
            kLongPressTimeout + const Duration(milliseconds: 100),
          );
          await press.up();
          await tester.pumpAndSettle();
          expect(editing.selection.isCollapsed, isFalse);
          final text = editing.text;
          final anchor = upwards
              ? editing.selection.end
              : editing.selection.start;
          final points = state.renderEditable.getEndpointsForSelection(
            editing.selection,
          );
          final handle =
              state.renderEditable.localToGlobal(
                upwards ? points.first.point : points.last.point,
              ) +
              Offset(upwards ? -1 : 1, 1);
          final gesture = await tester.startGesture(handle);
          await tester.pump();
          await gesture.moveBy(Offset(0, upwards ? -30 : 30));
          await tester.pump();
          await gesture.moveTo(
            Offset(110, upwards ? rect.top + 4 : rect.bottom - 4),
          );
          await tester.pump(const Duration(milliseconds: 100));
          var previous = scroll.offset;
          final before = previous;
          final selection = editing.selection;
          for (var i = 0; i < 120; i++) {
            await tester.pump(const Duration(milliseconds: 16));
            expect(
              scroll.offset,
              upwards
                  ? lessThanOrEqualTo(previous + 0.01)
                  : greaterThanOrEqualTo(previous - 0.01),
              reason: 'No opposing caret reveal at frame $i',
            );
            expect(
              (scroll.offset - previous).abs(),
              lessThanOrEqualTo(20),
              reason: 'A 16ms edge frame must not jump toward the fixed caret',
            );
            previous = scroll.offset;
            expect(
              upwards ? editing.selection.end : editing.selection.start,
              anchor,
            );
          }
          debugPrint(
            'HOME HANDLE ${live ? 'live' : 'source'} ${upwards ? 'up' : 'down'}: $before -> $previous, $selection -> ${editing.selection}',
          );
          expect(
            previous,
            upwards ? lessThan(before - 100) : greaterThan(before + 100),
          );
          expect(editing.selection, isNot(selection));
          expect(editing.text, text);
          if (upwards) {
            await gesture.up();
          } else {
            await gesture.cancel();
          }
          await tester.pump(const Duration(milliseconds: 200));
          final stopped = scroll.offset;
          await tester.pump(const Duration(milliseconds: 500));
          expect(scroll.offset, stopped);
          expect(
            identical(
              state,
              tester.state<EditableTextState>(
                find.descendant(of: field, matching: find.byType(EditableText)),
              ),
            ),
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}
