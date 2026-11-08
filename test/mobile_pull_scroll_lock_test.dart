import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:silique/ui/top_pull_dismiss.dart';

import 'mobile_editor_layout_test.dart' show openPhone;

void main() {
  for (final source in [false, true]) {
    testWidgets(
      'claimed dismiss pull freezes note scroll even when finger reverses source=$source',
      (tester) async {
        await openPhone(tester, long: true);
        if (source) {
          await tester.ensureVisible(
            find.byTooltip('Markdown / podgląd na żywo'),
          );
          await tester.tap(find.byTooltip('Markdown / podgląd na żywo'));
          await tester.pumpAndSettle();
        }
        final field = source
            ? find.byKey(const Key('mobile-note-scroll'))
            : find.byKey(const ValueKey('livemd-document-field'));
        final scroll = tester
            .widget<SingleChildScrollView>(
              find.byKey(const Key('mobile-note-scroll')),
            )
            .controller!;
        final start = const Offset(195, 420);
        final gesture = await tester.startGesture(start);
        await gesture.moveTo(start + const Offset(0, 120));
        await tester.pump(const Duration(milliseconds: 20));
        expect(scroll.offset, 0);
        for (var dy = 110; dy >= 40; dy -= 10) {
          await gesture.moveTo(start + Offset(0, dy.toDouble()));
          await tester.pump(const Duration(milliseconds: 20));
        }
        final scrollables = find.descendant(
          of: find.byType(TopPullDismiss),
          matching: find.byType(Scrollable),
        );
        for (final element in scrollables.evaluate()) {
          final position = (tester.state<ScrollableState>(
            find.byElementPredicate((e) => identical(e, element)),
          )).position;
          if (axisDirectionToAxis(position.axisDirection) == Axis.vertical) {
            expect(
              position.pixels,
              0,
              reason: 'All document scroll positions must stay frozen',
            );
          }
        }
        expect(
          scroll.offset,
          0,
          reason: 'Reversing a claimed dismissal must move the document surface, not scroll its text',
        );
        await gesture.up();
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);
        expect(field, findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }
}
