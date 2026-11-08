import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livemd_flutter/livemd_flutter.dart';
import 'package:silique/ui/mobile_note_viewport.dart';

void main() {
  for (final scenario in [
    (direction: TextDirection.ltr, release: 'up'),
    (direction: TextDirection.rtl, release: 'cancel'),
    (direction: TextDirection.ltr, release: 'multitouch'),
  ]) {
    final rtl = scenario.direction == TextDirection.rtl;
    testWidgets(
      'overlapping native end target keeps its source anchor during stationary lower-edge scrolling ${scenario.direction} ${scenario.release}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.reset);
        // A Latin run inside an RTL paragraph also guards against mapping
        // handle identity from the individual run's direction.
        const linePrefix = 'prefix i words on line ';
        final text = List.generate(160, (i) => '$linePrefix$i').join('\n');
        final editing = TextEditingController(text: text);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: Scaffold(
              appBar: AppBar(title: const Text('Editor')),
              body: MobileNoteViewport(
                heading: const SizedBox(height: 100),
                selectionController: editing,
                bodyBuilder: (_) => Builder(
                  builder: (context) => TextField(
                    controller: editing,
                    textDirection: scenario.direction,
                    selectionControls: TextSelectionEdgeAutoScroll.controlsOf(
                      context,
                    ),
                    style: const TextStyle(fontSize: 10, height: 1.4),
                    maxLines: null,
                    scrollPhysics: const NeverScrollableScrollPhysics(),
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(horizontal: 40),
                    ),
                  ),
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
        final state = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        final render = state.renderEditable;
        final wordOffset = text.indexOf('${linePrefix}35') + 7;
        final caret = render.getLocalRectForCaret(
          TextPosition(offset: wordOffset),
        );
        scroll.jumpTo(
          render.localToGlobal(caret.center).dy -
              tester.getRect(viewport).center.dy,
        );
        await tester.pumpAndSettle();
        final press = await tester.startGesture(
          render.localToGlobal(caret.center) + const Offset(4, 0),
        );
        await tester.pump(
          kLongPressTimeout + const Duration(milliseconds: 100),
        );
        await press.up();
        await tester.pumpAndSettle();
        expect(editing.selection.textInside(text), 'i');
        expect(render.textDirection, scenario.direction);
        expect(editing.selection.start, wordOffset);
        final initial = editing.selection;
        final endpoints = render.getEndpointsForSelection(initial);
        expect(endpoints.first.direction, TextDirection.ltr);
        expect(endpoints.last.direction, TextDirection.ltr);
        final start = render.localToGlobal(endpoints.first.point);
        final end = render.localToGlobal(endpoints.last.point);
        final controls = state.widget.selectionControls!;
        final size = controls.getHandleSize(render.preferredLineHeight);
        final startTarget =
            (start -
                controls.getHandleAnchor(
                  rtl
                      ? TextSelectionHandleType.right
                      : TextSelectionHandleType.left,
                  render.preferredLineHeight,
                )) &
            size;
        final endTarget =
            (end -
                controls.getHandleAnchor(
                  rtl
                      ? TextSelectionHandleType.left
                      : TextSelectionHandleType.right,
                  render.preferredLineHeight,
                )) &
            size;
        final hit = start + const Offset(-1, 1);
        debugPrint(
          'OVERLAP targets: $start / $end, $startTarget / $endTarget, hit=$hit',
        );
        expect(size, const Size(48, 48));
        expect(startTarget.contains(hit), isTrue);
        expect(endTarget.contains(hit), isTrue);
        expect((hit - start).distance, lessThan((hit - end).distance));
        final gesture = await tester.startGesture(hit);
        await tester.pump();
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        await gesture.moveBy(const Offset(0, 30));
        await tester.pump();
        expect(editing.selection.start, initial.start);
        expect(
          editing.selection.end,
          greaterThan(initial.end),
          reason: 'The topmost native END handle must actually move before edge scrolling',
        );
        debugPrint(
          'OVERLAP native end moved: $initial -> ${editing.selection}',
        );
        await gesture.moveTo(
          Offset(hit.dx, tester.getRect(viewport).bottom - 4),
        );
        await tester.pump(const Duration(milliseconds: 100));
        final beforeScroll = scroll.offset;
        final beforeSelection = editing.selection;
        var previousScroll = beforeScroll;
        var previousEndpoint = beforeSelection.extentOffset;
        var checkpointEndpoint = previousEndpoint;
        for (var frame = 0; frame < 120; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
          expect(scroll.offset, greaterThanOrEqualTo(previousScroll - 0.01));
          expect(scroll.offset - previousScroll, lessThanOrEqualTo(20));
          expect(
            editing.selection.baseOffset,
            initial.start,
            reason: 'The opposite SOURCE offset stays fixed at frame $frame',
          );
          expect(
            editing.selection.extentOffset,
            greaterThanOrEqualTo(previousEndpoint),
          );
          if (frame == 59 || frame == 119) {
            expect(
              editing.selection.extentOffset,
              greaterThan(checkpointEndpoint),
              reason: 'Each stationary hold interval must keep extending the endpoint',
            );
            checkpointEndpoint = editing.selection.extentOffset;
          }
          previousEndpoint = editing.selection.extentOffset;
          previousScroll = scroll.offset;
        }
        debugPrint(
          'OVERLAP held edge: $beforeScroll -> ${scroll.offset}, '
          '$beforeSelection -> ${editing.selection}',
        );
        expect(scroll.offset, greaterThan(beforeScroll + 100));
        expect(
          editing.selection.extentOffset,
          greaterThan(beforeSelection.extentOffset),
          reason:
              'A stationary end handle must keep growing the selected range',
        );
        expect(editing.text, text);
        if (scenario.release == 'multitouch') {
          final second = await tester.startGesture(
            render.localToGlobal(
                  render.getEndpointsForSelection(editing.selection).last.point,
                ) +
                const Offset(1, 1),
            pointer: 99,
          );
          await tester.pump(const Duration(milliseconds: 200));
          final interrupted = scroll.offset;
          await tester.pump(const Duration(milliseconds: 500));
          expect(
            scroll.offset,
            interrupted,
            reason: 'A second pointer must stop raw overlay edge scrolling',
          );
          await second.up();
          await gesture.up();
        } else if (scenario.release == 'cancel') {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump(const Duration(milliseconds: 200));
        final stopped = scroll.offset;
        await tester.pump(const Duration(milliseconds: 500));
        expect(scroll.offset, stopped);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        editing.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
