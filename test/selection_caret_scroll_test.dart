import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mobile_editor_layout_test.dart' show documentPosition, openPhone;

void main() {
  testWidgets(
    'keyboard metrics never recenter an expanded selection onto its old caret line',
    (tester) async {
      await openPhone(tester, long: true);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      final widget = tester.widget<TextField>(field);
      await tester.tapAt(const Offset(110, 400));
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      final gesture = await tester.startGesture(const Offset(110, 400));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      widget.controller!.selection = const TextSelection(
        baseOffset: 1600,
        extentOffset: 1500,
      );
      await tester.pumpAndSettle();
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('mobile-note-scroll')),
          )
          .controller!
          .jumpTo(300);
      await tester.pump();
      final before = documentPosition(tester).pixels;
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(
        documentPosition(tester).pixels,
        closeTo(before, 1),
        reason: 'Expanded selection belongs to the user; metrics must not force its old caret onscreen',
      );
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'upward long-press selection never snaps back to caret while keyboard is open',
    (tester) async {
      await openPhone(tester, long: true);
      final field = find.byKey(const ValueKey('livemd-document-field'));
      final widget = tester.widget<TextField>(field);
      await tester.tapAt(const Offset(110, 400));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const Key('mobile-note-scroll')),
          )
          .controller!
          .jumpTo(1200);
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(const Offset(110, 400));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      expect(widget.controller!.selection.isCollapsed, isFalse);
      await gesture.moveTo(const Offset(135, 60));
      await tester.pump(const Duration(milliseconds: 30));
      var previous = documentPosition(tester).pixels;
      final before = previous;
      for (var i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(
          documentPosition(tester).pixels,
          lessThanOrEqualTo(previous + 0.5),
          reason:
              'Selection scrolling must not fight caret visibility at frame $i',
        );
        previous = documentPosition(tester).pixels;
      }
      expect(previous, lessThan(before - 150));
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
