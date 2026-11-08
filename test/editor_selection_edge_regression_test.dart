import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';

void main() {
  for (final height in [80.0, 400.0]) {
    for (final live in [true, false]) {
      for (final upwards in [false, true]) {
        testWidgets(
          '${live ? 'live' : 'source'} long press extends selection while held near ${upwards ? 'top' : 'bottom'} edge height=$height',
          (tester) async {
            final text = List.generate(
              100,
              (i) => 'Line $i words for selection 😀',
            ).join('\n');
            final controller = LiveMarkdownController(text: text);
            final scroll = ScrollController();
            final source = TextEditingController(text: text);
            await tester.pumpWidget(
              MaterialApp(
                theme: ThemeData(platform: TargetPlatform.android),
                home: Scaffold(
                  body: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: 320,
                      height: height,
                      child: live
                          ? LiveMarkdownEditor(
                              controller: controller,
                              scrollController: scroll,
                            )
                          : TextSelectionEdgeAutoScroll(
                              controller: source,
                              scrollController: scroll,
                              child: TextField(
                                controller: source,
                                scrollController: scroll,
                                expands: true,
                                minLines: null,
                                maxLines: null,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
            if (upwards) {
              scroll.jumpTo(900);
              await tester.pumpAndSettle();
            }
            final editable = tester
                .state<EditableTextState>(find.byType(EditableText))
                .renderEditable;
            final rect = Rect.fromPoints(
              editable.localToGlobal(Offset.zero),
              editable.localToGlobal(editable.size.bottomRight(Offset.zero)),
            );
            final gesture = await tester.startGesture(
              Offset(rect.left + 65, rect.center.dy),
            );
            await tester.pump(
              kLongPressTimeout + const Duration(milliseconds: 100),
            );
            final editing = tester
                .widget<EditableText>(find.byType(EditableText))
                .controller;
            expect(editing.selection.isCollapsed, isFalse);
            await gesture.moveTo(
              Offset(rect.left + 90, upwards ? rect.top + 5 : rect.bottom - 5),
            );
            await tester.pump(const Duration(milliseconds: 30));
            final offset = scroll.offset;
            final selection = editing.selection;
            for (var i = 0; i < 8; i++) {
              await tester.pump(const Duration(milliseconds: 100));
            }
            expect(
              scroll.offset,
              upwards ? lessThan(offset) : greaterThan(offset),
              reason: 'Holding near the viewport edge must keep scrolling without more pointer moves',
            );
            expect(
              editing.selection,
              isNot(selection),
              reason: 'Scrolling must extend the selected document range',
            );
            debugPrint(
              'EDGE ${live ? 'live' : 'source'} ${upwards ? 'up' : 'down'}: $offset -> ${scroll.offset}, selection $selection -> ${editing.selection}',
            );
            expect(controller.text, text);
            expect(editing.text, text);
            if (upwards && live) {
              // Dispose while the pointer and edge animation are still active.
              await tester.pumpWidget(const SizedBox());
              await gesture.cancel();
            } else {
              if (upwards) {
                await gesture.up();
              } else {
                await gesture.cancel();
              }
              await tester.pump(const Duration(milliseconds: 150));
              final stopped = scroll.offset;
              await tester.pump(const Duration(seconds: 1));
              expect(scroll.offset, stopped);
              await tester.pumpWidget(const SizedBox());
            }
            await tester.pump(const Duration(seconds: 1));
            expect(tester.takeException(), isNull);
            scroll.dispose();
            controller.dispose();
            source.dispose();
          },
        );
      }
    }
  }

  testWidgets(
    'ordinary pan with an old selection never starts edge scrolling',
    (tester) async {
      final text = List.generate(
        100,
        (i) => 'Line $i selection text',
      ).join('\n');
      final controller = TextEditingController(text: text);
      final scroll = ScrollController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 400,
              child: TextSelectionEdgeAutoScroll(
                controller: controller,
                scrollController: scroll,
                child: TextField(
                  controller: controller,
                  scrollController: scroll,
                  expands: true,
                  minLines: null,
                  maxLines: null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.showKeyboard(find.byType(TextField));
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 4,
      );
      scroll.jumpTo(500);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(70, 200));
      await gesture.moveTo(const Offset(70, 30));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      await gesture.moveTo(const Offset(70, 6));
      await tester.pump(const Duration(milliseconds: 100));
      final stopped = scroll.offset;
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(scroll.offset, stopped);
      expect(controller.text, text);
      await gesture.cancel();
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      controller.dispose();
    },
  );
}
